defmodule Mix.Release do
  @moduledoc """
  Defines the release structure and convenience for assembling releases.
  """

  @doc """
  The Mix.Release struct has the following fields:

    * `:name` - the name of the release as an atom
    * `:version` - the version of the release as a string
    * `:path` - the path to the release root
    * `:version_path` - the path to the release version inside the release
    * `:applications` - a list of application release definitions
    * `:erts_source` - the erts source as a charlist (or nil)
    * `:erts_version` - the erts version as a charlist
    * `:config_source` - the path to the build configuration source (or nil)
    * `:consolidation_source` - the path to consolidated protocols source (or nil)
    * `:options` - a keyword list with all other user supplied release options

  """
  defstruct [
    :name,
    :version,
    :path,
    :version_path,
    :applications,
    :erts_source,
    :erts_version,
    :config_source,
    :consolidation_source,
    :options
  ]

  @type mode :: :permanent | :transient | :temporary | :load | :none
  @type application :: {atom(), charlist(), mode} | {atom(), charlist(), mode, [atom()]}
  @type t :: %{
          name: atom(),
          version: String.t(),
          path: String.t(),
          version_path: String.t(),
          applications: [application],
          erts_version: charlist(),
          erts_source: charlist() | nil,
          config_source: String.t() | nil,
          consolidation_source: String.t() | nil,
          options: keyword()
        }

  @default_apps %{iex: :permanent, elixir: :permanent, sasl: :permanent}
  @valid_modes [:permanent, :temporary, :transient, :load, :none]
  @significant_chunks ~w(Atom AtU8 Attr Code StrT ImpT ExpT FunT LitT Line)c
  @copy_app_dirs ["include", "priv"]

  @doc false
  @spec from_config!(atom, keyword, keyword) :: t
  def from_config!(name, config, overrides) do
    {name, apps, opts} = find_release(name, config)
    apps = Map.merge(@default_apps, apps)

    opts =
      [force: false, quiet: false, strip_beams: false]
      |> Keyword.merge(opts)
      |> Keyword.merge(overrides)

    {include_erts, opts} = Keyword.pop(opts, :include_erts, true)
    {erts_source, erts_version} = erts_data(include_erts)

    rel_apps =
      apps
      |> Map.keys()
      |> traverse_apps(%{}, apps)
      |> Map.values()
      |> Enum.sort()

    {path, opts} =
      Keyword.pop_lazy(opts, :path, fn ->
        Path.join([Mix.Project.build_path(config), "rel", Atom.to_string(name)])
      end)

    {version, opts} =
      Keyword.pop_lazy(opts, :version, fn ->
        config[:version] ||
          Mix.raise(
            "No :version found. Please make sure a :version is set in your project definition " <>
              "or inside the release the configuration"
          )
      end)

    consolidation_source =
      if config[:consolidate_protocols] do
        Mix.Project.consolidation_path(config)
      end

    config_source =
      if File.regular?(config[:config_path]) do
        config[:config_path]
      end

    %Mix.Release{
      name: name,
      version: version,
      path: path,
      version_path: Path.join([path, "releases", version]),
      erts_source: erts_source,
      erts_version: erts_version,
      applications: rel_apps,
      consolidation_source: consolidation_source,
      config_source: config_source,
      options: opts
    }
  end

  defp erts_data(false) do
    {nil, :erlang.system_info(:version)}
  end

  defp erts_data(true) do
    version = :erlang.system_info(:version)
    {:filename.join(:code.root_dir(), 'erts-#{version}'), version}
  end

  defp erts_data(erts_source) when is_binary(erts_source) do
    if File.exists?(erts_source) do
      [_, erts_version] = erts_source |> Path.basename() |> String.split("-")
      {to_charlist(erts_source), to_charlist(erts_version)}
    else
      Mix.raise("Could not find ERTS system at #{inspect(erts_source)}")
    end
  end

  # TODO: Support name
  defp find_release(_name, config) do
    {name, opts} = lookup_release(config) || infer_release(config)
    {apps, opts} = Keyword.pop(opts, :applications, [])
    apps = Map.new(apps)

    if Mix.Project.umbrella?(config) do
      if apps == %{} do
        Mix.raise(
          "No applications found for release #{inspect(name)}. " <>
            "Releases inside umbrella must have :applications set to a non-empty list"
        )
      end

      {name, apps, opts}
    else
      {name, Map.put_new(apps, Keyword.fetch!(config, :app), :permanent), opts}
    end
  end

  defp lookup_release(_config) do
    # TODO: Implement me
    nil
  end

  defp infer_release(config) do
    if Mix.Project.umbrella?(config) do
      Mix.raise("TODO: we can't infer, raise nice error")
    else
      {Keyword.fetch!(config, :app), []}
    end
  end

  defp traverse_apps(apps, seen, modes) do
    for app <- apps,
        not Map.has_key?(seen, app),
        reduce: seen do
      seen -> traverse_app(app, seen, modes)
    end
  end

  defp traverse_app(app, seen, modes) do
    mode = Map.get(modes, app, :permanent)

    unless mode in @valid_modes do
      Mix.raise(
        "unknown mode #{inspect(mode)} for #{inspect(app)}. " <>
          "Valid modes are: #{inspect(@valid_modes)}"
      )
    end

    case :file.consult(Application.app_dir(app, "ebin/#{app}.app")) do
      {:ok, terms} ->
        [{:application, ^app, properties}] = terms
        seen = Map.put(seen, app, build_app_for_release(app, mode, properties))
        traverse_apps(Keyword.get(properties, :applications, []), seen, modes)

      {:error, reason} ->
        Mix.raise("Could not load #{app}.app. Reason: #{inspect(reason)}")
    end
  end

  defp build_app_for_release(app, mode, properties) do
    vsn = Keyword.fetch!(properties, :vsn)

    case Keyword.get(properties, :included_applications, []) do
      [] -> {app, vsn, mode}
      included_apps -> {app, vsn, mode, included_apps}
    end
  end

  @doc """
  Copies ERTS if the release is configured to do so.

  Returns true if the release was copied, false otherwise.
  """
  @spec copy_erts(t) :: boolean()
  def copy_erts(%{erts_source: nil}) do
    false
  end

  def copy_erts(release) do
    destination = Path.join(release.path, "erts-#{release.erts_version}")
    File.cp_r!(release.erts_source, destination)

    _ = File.rm(Path.join(destination, "bin/erl"))
    _ = File.rm(Path.join(destination, "bin/erl.init"))

    destination
    |> Path.join("bin/erl")
    |> File.write!(~S"""
    #!/bin/sh
    SELF=$(readlink "$0" || true)
    if [ -z "$SELF" ]; then SELF="$0"; fi
    BINDIR="$(cd "$(dirname "$SELF")" && pwd -P)"
    ROOTDIR="$(dirname "$(dirname "$BINDIR")")"
    EMU=beam
    PROGNAME=$(echo $0 | sed 's/.*\///')
    export EMU
    export ROOTDIR
    export BINDIR
    export PROGNAME
    exec "$BINDIR/erlexec" ${1+"$@"}
    """)

    File.chmod!(Path.join(destination, "bin/erl"), 0o744)
    true
  end

  @doc """
  Copies the given application specification into the release.

  It assumes the application exists.
  """
  # TODO: Do not copy ERTS apps if include ERTS is false
  @spec copy_app(t, application) :: :ok
  def copy_app(release, app_spec) do
    app = elem(app_spec, 0)
    vsn = elem(app_spec, 1)

    source_app = Application.app_dir(app)
    target_app = Path.join([release.path, "lib", "#{app}-#{vsn}"])

    File.rm_rf!(target_app)
    File.mkdir_p!(target_app)

    copy_ebin(release, Path.join(source_app, "ebin"), Path.join(target_app, "ebin"))

    for dir <- @copy_app_dirs do
      source_dir = Path.join(source_app, dir)
      target_dir = Path.join(target_app, dir)
      File.exists?(source_dir) && File.cp_r!(source_dir, target_dir)
    end

    :ok
  end

  @doc """
  Copies the ebin directory at `source` to `target`
  respecting release options such a `:strip_beams`.
  """
  @spec copy_ebin(t, Path.t(), Path.t()) :: {:ok, [String.t()]} | {:error, File.posix()}
  def copy_ebin(release, source, target) do
    with {:ok, [_ | _] = files} <- File.ls(source) do
      File.mkdir_p!(target)
      strip_beams? = Keyword.get(release.options, :strip_beams, true)

      for file <- files do
        source_file = Path.join(source, file)
        target_file = Path.join(target, file)

        with true <- strip_beams? and String.ends_with?(file, ".beam"),
             {:ok, {_, chunks}} <- read_significant_chunks(File.read!(source_file)) do
          File.write!(target_file, build_beam(chunks))
        else
          _ -> File.copy(source_file, target_file)
        end
      end

      {:ok, files}
    end
  end

  defp read_significant_chunks(binary) do
    :beam_lib.chunks(binary, @significant_chunks, [:allow_missing_chunks])
  end

  defp build_beam(chunks) do
    chunks = for {name, chunk} <- chunks, is_binary(chunk), do: {name, chunk}
    {:ok, binary} = :beam_lib.build_module(chunks)
    {:ok, fd} = :ram_file.open(binary, [:write, :binary])
    {:ok, _} = :ram_file.compress(fd)
    {:ok, binary} = :ram_file.get_file(fd)
    :ok = :ram_file.close(fd)
    binary
  end
end
