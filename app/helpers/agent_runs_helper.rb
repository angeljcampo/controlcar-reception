module AgentRunsHelper
  # Small colored circle + glyph that visually distinguishes the three
  # AgentRun states in the timeline list.
  def agent_run_status_icon(run)
    case run.status
    when "succeeded"
      status_glyph("✓", "bg-emerald-100 text-emerald-700", label: t("agent_runs.status.succeeded"))
    when "failed"
      status_glyph("✗", "bg-red-100 text-red-700", label: t("agent_runs.status.failed"))
    when "running"
      status_glyph("⟳", "bg-blue-100 text-blue-700 animate-spin", label: t("agent_runs.status.running"))
    else
      status_glyph("?", "bg-zinc-100 text-zinc-600", label: run.status.to_s)
    end
  end

  # Dispatcher for the four log entry types captured by BaseAgent. Each
  # entry is a Hash with a "type" key ("initial_input", "llm_response",
  # "tool_call", "final_output"). Returns rendered HTML.
  def render_log_entry(entry, index)
    type = entry["type"] || entry[:type]
    case type
    when "initial_input" then render_initial_input_entry(entry, index)
    when "llm_response"  then render_llm_response_entry(entry, index)
    when "tool_call"     then render_tool_call_entry(entry, index)
    when "final_output"  then render_final_output_entry(entry, index)
    else
      tag.div("Unknown log entry: #{type}", class: "text-body-sm text-on-surface-variant italic")
    end
  end

  private

  def status_glyph(glyph, color_classes, label:)
    tag.span(glyph,
             class: "inline-flex items-center justify-center w-5 h-5 rounded-full text-xs font-bold #{color_classes}",
             title: label,
             aria: { label: label })
  end

  # ── Log entry renderers ──────────────────────────────────────────
  # All entries are jsonb in Postgres, so keys come back as STRINGS.
  # We dig with both string and symbol keys to stay robust.

  # First entry of every run: what we sent to the LLM. Shows the system
  # prompt + the user content. Image parts collapse to "[image · mime]"
  # so the panel stays scannable (no base64 dumps).
  def render_initial_input_entry(entry, _index)
    system_prompt = fetch_log(entry, :system_prompt)
    user_content  = fetch_log(entry, :user_content) || []

    tag.div(class: "rounded-lg border border-sky-200 bg-sky-50/60 p-3") do
      header = tag.div("Input enviado al LLM",
                       class: "text-label-md uppercase text-sky-900 font-semibold mb-2")

      sections = []

      if system_prompt.present?
        sections << details_block("System prompt (#{system_prompt.length} chars)", system_prompt)
      end

      user_messages = Array(user_content).select { |m| fetch_log(m, :role) == "user" }
      user_messages.each do |msg|
        parts = Array(fetch_log(msg, :content))
        text_parts  = parts.select { |p| fetch_log(p, :type) == "text" }
        image_parts = parts.select { |p| fetch_log(p, :type) == "image" }

        text_parts.each do |part|
          sections << tag.div(class: "mt-2") do
            safe_join([
              tag.p("Mensaje del usuario", class: "text-label-md text-sky-800 font-semibold uppercase mb-1"),
              tag.pre(fetch_log(part, :text),
                      class: "bg-surface-container-lowest border border-outline-variant rounded p-2 text-[12px] font-mono whitespace-pre-wrap break-words")
            ])
          end
        end

        if image_parts.any?
          sections << tag.div(class: "mt-2") do
            header = tag.p("Imágenes adjuntas (#{image_parts.size})",
                           class: "text-label-md text-sky-800 font-semibold uppercase mb-1")
            rows = image_parts.map do |p|
              mime  = fetch_log(p, :mime)
              bytes = fetch_log(p, :bytes)
              magic = fetch_log(p, :magic_bytes)
              size_kb = bytes ? "#{(bytes / 1024.0).round(1)} KB" : nil
              # Magic bytes are the file's actual format signature (JPEG
              # always starts with FF D8 FF, PNG with 89 50 4E 47, etc.).
              # Showing them here proves the agent got real image bytes,
              # not nil or an empty placeholder.
              parts = [
                tag.code(mime, class: "bg-white px-1.5 py-0.5 rounded text-[11px]"),
                size_kb,
                magic ? "magic: #{magic}" : nil
              ].compact
              tag.li(safe_join(parts, " · "), class: "text-body-sm text-on-surface")
            end
            list = tag.ul(safe_join(rows), class: "list-disc list-inside space-y-0.5 ml-1")
            safe_join([header, list])
          end
        end
      end

      safe_join([ header, *sections ])
    end
  end

  def render_llm_response_entry(entry, index)
    iteration = fetch_log(entry, :iteration)
    usage     = fetch_log(entry, :usage) || {}
    text      = fetch_log(entry, :text)
    tool_uses = fetch_log(entry, :tool_uses) || []

    in_tokens  = fetch_log(usage, :prompt_tokens).to_i
    out_tokens = fetch_log(usage, :completion_tokens).to_i

    tag.div(class: "rounded-lg border border-indigo-200 bg-indigo-50/60 p-3") do
      header = tag.div(class: "flex items-center justify-between mb-1") do
        safe_join([
          tag.span("Iteración #{iteration} · Respuesta del LLM",
                   class: "text-label-md uppercase text-indigo-900 font-semibold"),
          tag.span("#{in_tokens} + #{out_tokens} tokens",
                   class: "text-body-sm text-indigo-700")
        ])
      end

      body_parts = []
      if text.present?
        body_parts << tag.p(text, class: "text-body-sm text-on-surface mt-1 whitespace-pre-wrap leading-relaxed")
      end
      if tool_uses.any?
        names = tool_uses.map { |tu| fetch_log(tu, :name) }.compact
        body_parts << tag.p(class: "text-body-sm text-indigo-900 mt-1") do
          safe_join([
            tag.span("Llamadas a tools: ", class: "font-medium"),
            tag.span(names.map { |n| "<code class='bg-white px-1.5 py-0.5 rounded text-[11px]'>#{n}</code>" }.join(" ").html_safe)
          ])
        end
      end
      safe_join([ header, *body_parts ])
    end
  end

  def render_tool_call_entry(entry, _index)
    name      = fetch_log(entry, :name)
    iteration = fetch_log(entry, :iteration)
    arguments = fetch_log(entry, :arguments)
    result    = fetch_log(entry, :result)
    error     = fetch_log(entry, :error)
    failed    = error.present?

    bg = failed ? "bg-red-50 border-red-200" : "bg-emerald-50/60 border-emerald-200"
    accent = failed ? "text-red-900" : "text-emerald-900"

    tag.div(class: "rounded-lg border #{bg} p-3") do
      header = tag.div(class: "flex items-center justify-between mb-1") do
        safe_join([
          tag.span(class: "text-label-md uppercase #{accent} font-semibold") do
            safe_join([
              "Iteración #{iteration} · Tool call: ",
              tag.code(name, class: "bg-white px-1.5 py-0.5 rounded text-[11px] normal-case")
            ])
          end,
          (failed ? tag.span("error", class: "text-body-sm text-red-700") : nil)
        ].compact)
      end

      body_parts = [
        details_block("Argumentos", arguments)
      ]
      if failed
        body_parts << tag.p(error, class: "text-body-sm text-red-900 mt-2 font-mono")
      else
        body_parts << details_block("Resultado", result)
      end

      safe_join([ header, *body_parts ])
    end
  end

  def render_final_output_entry(entry, _index)
    args = fetch_log(entry, :args)

    tag.div(class: "rounded-lg border border-amber-200 bg-amber-50/70 p-3") do
      header = tag.div("Output final estructurado",
                       class: "text-label-md uppercase text-amber-900 font-semibold mb-1")
      body = details_block("Ver datos del análisis", args)
      safe_join([ header, body ])
    end
  end

  # Collapsible <details> block with pretty-printed JSON inside.
  def details_block(label, data)
    json = begin
      JSON.pretty_generate(data)
    rescue StandardError
      data.to_s
    end

    tag.details(class: "mt-2") do
      safe_join([
        tag.summary(label, class: "text-body-sm text-on-surface-variant cursor-pointer hover:text-on-surface select-none"),
        tag.pre(json, class: "mt-2 bg-surface-container-lowest border border-outline-variant rounded p-2 text-[11px] font-mono whitespace-pre-wrap break-words overflow-x-auto max-h-64")
      ])
    end
  end

  # JSON columns come back with string keys; ruby hashes use symbols. Try both.
  def fetch_log(hash, key)
    return nil if hash.nil?
    hash[key.to_s] || hash[key.to_sym]
  end
end
