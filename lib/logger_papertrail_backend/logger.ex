defmodule LoggerPapertrailBackend.Logger do
  @behaviour :gen_event
  import LoggerPapertrailBackend.Configurator
  @moduledoc false

  # Most of this is shamelessy copied from :console-backend

  @default_format "[$level] $levelpad$metadata $message"

  def init(__MODULE__) do
    if Process.whereis(:user) do
      init({:user, []})
    else
      {:error, :ignore}
    end
  end

  def init({device, opts}) do
    state = configure(device, opts)
    {:ok, state}
  end

  def handle_call({:configure, options}, state) do
   state = configure(state.device, options)
    {:ok, :ok, state}
  end

  def handle_event({_level, gl, _event}, state) when node(gl) != node() do
    {:ok, state}
  end

  def handle_event({level, _gl, {Logger, msg, ts, md}}, %{metadata_filter: metadata_filter} = state) do
    if meet_level?(level, state.level) and metadata_matches?(md, metadata_filter) do
      log_event(level, msg, ts, md, state)
    end
    {:ok, state}
  end
  def handle_event(_, state) do
    {:ok, state}
  end

  def handle_info(_, state) do
    {:ok, state}
  end

  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  def terminate(_reason, _state) do
    :ok
  end


  ## Helpers

  defp meet_level?(_lvl, nil), do: true

  defp meet_level?(lvl, min) do
    Logger.compare_levels(lvl, min) != :lt
  end

  defp configure(device, options) do
    config =
      Application.get_env(:logger, :logger_papertrail_backend, [])
      |> configure_merge(options)

    if device === :user do
      Application.put_env(:logger, :logger_papertrail_backend, config)
    end

    format =
      Keyword.get(config, :format, @default_format)
      |> Logger.Formatter.compile

    level    = Keyword.get(config, :level)
    metadata = Keyword.get(config, :metadata, [])
    metadata_filter = Keyword.get(config, :metadata_filter)

    target_config = configure_papertrail_target(config)

    colors   = configure_colors(config)

    %{format: format,
      metadata: metadata,
      metadata_filter: metadata_filter,
      level: level,
      colors: colors,
      device: device,
      host: target_config.host,
      port: target_config.port,
      system_name: target_config.system_name }
  end

  defp configure_merge(env, options) do
    Keyword.merge(env, options, fn
      :colors, v1, v2 -> Keyword.merge(v1, v2)
      _, _v1, v2 -> v2
    end)
  end

  defp configure_colors(config) do
    colors = Keyword.get(config, :colors, [])
    %{debug: Keyword.get(colors, :debug, :cyan),
      info: Keyword.get(colors, :info, :normal),
      warn: Keyword.get(colors, :warn, :yellow),
      warning: Keyword.get(colors, :warn, :yellow),
      error: Keyword.get(colors, :error, :red),
      enabled: Keyword.get(colors, :enabled, IO.ANSI.enabled?)}
  end


  defp log_event(level, msg, ts, md, %{colors: colors, system_name: system_name} = state) do
    application =
      [
        # From metadata
        Keyword.get(md, :system_name),
        # From config
        system_name,
        # From running application
        Keyword.get(md, :application),
        # Default
        "unknown_elixir_application"
      ]
      |> Enum.find(& &1)
    procid = Keyword.get(md, :module, nil)

    format_event(level, msg, ts, md, state)
      |> color_event(level, colors)
      |> LoggerPapertrailBackend.MessageBuilder.build(level, application, ts, procid)
      |> LoggerPapertrailBackend.Sender.send(state.host, state.port)
  end

  defp format_event(level, msg, ts, md, %{format: format, metadata: keys}) do
    Logger.Formatter.format(format, level, msg, ts, take_metadata(md, keys))
  end

  defp take_metadata(metadata, keys) do
    Enum.reduce(keys, [], fn key, acc ->
      case Keyword.fetch(metadata, key) do
        {:ok, val} -> [{key, val} | acc]
        :error     -> acc
      end
    end) |> Enum.reverse()
  end

  defp color_event(data, _level, %{enabled: false}), do: data

  defp color_event(data, level, %{enabled: true} = colors) do
    [IO.ANSI.format_fragment(Map.fetch!(colors, level), true), data | IO.ANSI.reset]
  end

  defp metadata_matches?(_md, nil), do: true
  defp metadata_matches?(_md, []), do: true # all of the filter keys are present
  defp metadata_matches?(md, [{key, val}|rest]) do
    case Keyword.fetch(md, key) do
      {:ok, ^val} ->
        metadata_matches?(md, rest)
      _ -> false #fail on first mismatch
    end
  end
end
