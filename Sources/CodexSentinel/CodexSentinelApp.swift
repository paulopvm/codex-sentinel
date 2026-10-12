import SwiftUI
import Charts
import AppKit

@main
struct CodexSentinelApp: App {
    @NSApplicationDelegateAdaptor(SentinelAppDelegate.self) private var appDelegate
    @StateObject private var model = SentinelModel()

    var body: some Scene {
        Window(
            "Codex Sentinel",
            id: "main",
            content: {
                SentinelWindow()
                    .environmentObject(model)
                    .frame(minWidth: 780, minHeight: 560)
                    .background(DashboardWindowReference())
                    .task { model.startMonitoring() }
            }
        )
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(model)
                .frame(width: 330)
                .task { model.startMonitoring() }
        } label: {
            Label("Codex Sentinel", systemImage: model.usage?.allKnownLimitsAvailable == false ? "exclamationmark.triangle.fill" : "shield.lefthalf.filled")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 540, height: 620)
        }
    }
}

private final class SentinelAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private struct SentinelWindow: View {
    @EnvironmentObject private var model: SentinelModel
    @State private var selection: String? = "Visão geral"

    private let sections = ["Visão geral", "Conversas", "Histórico", "Configurações"]

    var body: some View {
        NavigationSplitView {
            List(sections, id: \.self, selection: $selection) { item in
                Label(item, systemImage: icon(for: item))
            }
            .navigationTitle("Sentinel")
            .listStyle(.sidebar)
        } detail: {
            Group {
                switch selection {
                case "Conversas": ThreadsView()
                case "Histórico": HistoryView()
                case "Configurações": SettingsView()
                default: DashboardView()
                }
            }
            .environmentObject(model)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { Task { await model.refresh() } } label: {
                    Label("Atualizar", systemImage: "arrow.clockwise")
                }
                .help("Atualizar cotas e conversas")
            }
        }
    }

    private func icon(for item: String) -> String {
        switch item {
        case "Conversas": "bubble.left.and.bubble.right"
        case "Histórico": "chart.xyaxis.line"
        case "Configurações": "gearshape"
        default: "gauge.with.dots.needle.50percent"
        }
    }
}

private struct MenuBarPanel: View {
    @EnvironmentObject private var model: SentinelModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex Sentinel").font(.headline)
                    Text(model.refreshProgress ?? model.connection.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(!model.preferences.monitoringEnabled)
            }

            if let usage = model.usage {
                if usage.windows.isEmpty {
                    ContentUnavailableView("Cotas indisponíveis", systemImage: "chart.bar.xaxis", description: Text("O Codex não retornou janelas de uso nesta conta."))
                        .frame(height: 130)
                } else {
                    ForEach(usage.windows) { window in QuotaRow(window: window) }
                }
            } else {
                Text(model.lastError ?? "Aguardando dados do Codex…")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Text("Conversas limitadas").font(.subheadline)
                Spacer()
                Text("\(model.threads.filter { $0.readiness == .rateLimited }.count)")
                    .font(.system(.body, design: .rounded).weight(.semibold))
            }
            Label(
                model.preferences.autoResumeEnabled ? "Retomada global ativa" : "Retomada global desativada",
                systemImage: model.preferences.autoResumeEnabled ? "arrow.clockwise.circle.fill" : "pause.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("Abrir painel") { showMainWindow() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("Encerrar") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .task { model.startMonitoring() }
    }

    private func showMainWindow() {
        openWindow(id: "main")
        WindowFocus.bringMainWindowForward()
    }
}

private struct DashboardWindowReference: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowMarker() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowMarker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { WindowFocus.attach(window) }
        }
    }
}

@MainActor
private enum WindowFocus {
    private static weak var dashboard: NSWindow?
    private static var pendingFocus = false

    static func attach(_ window: NSWindow) {
        dashboard = window
        if pendingFocus { scheduleFocus() }
    }

    static func bringMainWindowForward() {
        pendingFocus = true
        scheduleFocus()
    }

    private static func scheduleFocus() {
        // SwiftUI may attach the window after openWindow returns. Keep the request until
        // the marker supplies that window, then activate after the menu action finishes.
        DispatchQueue.main.async {
            guard pendingFocus, let window = dashboard else { return }
            pendingFocus = false
            if window.isMiniaturized { window.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

private struct DashboardView: View {
    @EnvironmentObject private var model: SentinelModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Visão geral").font(.largeTitle.bold())
                        Text(model.refreshProgress ?? model.lastRefresh.map { "Atualizado às \($0.formatted(date: .omitted, time: .shortened))" } ?? model.connection.label)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await model.refresh() } } label: { Label("Atualizar agora", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                }
                if let message = model.lastError {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
                if let usage = model.usage {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                        ForEach(usage.windows) { window in QuotaCard(window: window) }
                    }
                    if usage.windows.isEmpty {
                        ContentUnavailableView("Sem dados de cota", systemImage: "chart.bar.xaxis", description: Text("Os valores só aparecem quando o App Server os retorna."))
                    }
                    HStack(spacing: 12) {
                        MetricCard(title: "Plano informado pelo Codex", value: usage.planType ?? "Indisponível", symbol: "person.text.rectangle")
                        MetricCard(title: "Conversas recentes", value: "\(model.threads.count)", symbol: "bubble.left.and.bubble.right")
                        MetricCard(title: "Interrompidas por cota", value: "\(model.threads.filter { $0.readiness == .rateLimited }.count)", symbol: "pause.circle")
                    }
                } else {
                    ContentUnavailableView {
                        Label("Conecte ao Codex", systemImage: "terminal")
                    } description: {
                        Text(model.lastError ?? "O Sentinel consulta o App Server usando o executável Codex local.")
                    } actions: {
                        Button("Tentar novamente") { Task { await model.refresh() } }
                    }
                    .frame(minHeight: 280)
                }
                HStack {
                    Label("Retomada automática", systemImage: model.preferences.autoResumeEnabled ? "arrow.clockwise.circle.fill" : "pause.circle")
                    Text(model.preferences.autoResumeEnabled ? "Ativa para todos os chats elegíveis" : "Desativada")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(14)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(24)
        }
        .navigationTitle("Visão geral")
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold))
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct QuotaCard: View {
    let window: QuotaWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(window.title).font(.headline)
                Spacer()
                Image(systemName: window.isExhausted ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(window.isExhausted ? .orange : .green)
            }
            if let used = window.window.usedPercent {
                ProgressView(value: min(max(used, 0), 100), total: 100)
                HStack {
                    Text("\(used.formatted(.number.precision(.fractionLength(0...1))))% usado")
                    Spacer()
                    Text("\(max(0, 100 - used).formatted(.number.precision(.fractionLength(0...1))))% restante")
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Uso indisponível").font(.callout).foregroundStyle(.secondary)
            }
            if let reset = window.window.resetsAt, reset > 0 {
                Text("Reinicia \(Date(timeIntervalSince1970: reset).formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
    }
}

private struct QuotaRow: View {
    let window: QuotaWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.title).font(.caption.weight(.medium))
                Spacer()
                Text(window.window.usedPercent.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))%" } ?? "Indisponível")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let used = window.window.usedPercent { ProgressView(value: min(max(used, 0), 100), total: 100) }
        }
    }
}

private struct ThreadsView: View {
    @EnvironmentObject private var model: SentinelModel

    private var groups: [(String, [CodexThread])] {
        Dictionary(grouping: model.threads, by: \.projectName).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Conversas").font(.largeTitle.bold())
                    Text("A retomada é controlada por uma única opção global em Configurações.").foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.refresh() } } label: { Label("Atualizar", systemImage: "arrow.clockwise") }
            }.padding(20)
            if model.threads.isEmpty {
                ContentUnavailableView("Nenhuma conversa encontrada", systemImage: "bubble.left.and.bubble.right", description: Text(model.lastError ?? "Verifique se o Codex local está conectado."))
            } else {
                List {
                    ForEach(groups, id: \.0) { project, values in
                        Section(project) {
                            ForEach(values) { thread in ThreadRow(thread: thread) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Conversas")
    }
}

private struct ThreadRow: View {
    @EnvironmentObject private var model: SentinelModel
    let thread: CodexThread

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(thread.title).font(.body.weight(.medium)).lineLimit(1)
                Text(statusLabel + (thread.updatedAt.map { " · \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                if thread.readiness == .rateLimited {
                    Text("Erro de limite confirmado pelo App Server")
                        .font(.caption2).foregroundStyle(.orange)
                    Text(resumeMessage)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
        }
        .padding(.vertical, 5)
        .contextMenu { Button("Copiar ID da conversa") { NSPasteboard.general.setString(thread.id, forType: .string) } }
    }

    private var resumeMessage: String {
        guard model.preferences.autoResumeEnabled else { return "A retomada global está desativada." }
        let key = "\(thread.id):\(thread.lastTurnID ?? "")"
        guard let attempt = model.attempts.first(where: { $0.id == key }) else {
            return "Cota e estado serão verificados antes de retomar."
        }
        switch ResumeRetryPolicy.decision(for: attempt, now: Date()) {
        case .wait(let retryAt):
            return "Nova tentativa após \(retryAt.formatted(date: .omitted, time: .shortened)). \(attempt.message ?? "Verificando a última tentativa.")"
        case .start:
            return "Aguardando nova verificação. \(attempt.message ?? "")"
        case .skip:
            switch attempt.status {
            case .accepted: return "Retomada aceita; acompanhando o novo turno."
            case .completed: return "Retomada concluída."
            default: return attempt.message ?? "Novo turno registrado; aguardando confirmação do estado."
            }
        }
    }

    private var statusLabel: String {
        if let attempt = model.attempts.first(where: { $0.threadID == thread.id && $0.startedTurnID != nil && $0.startedTurnID == thread.lastTurnID }),
           [.accepted, .unknown].contains(attempt.status), thread.readiness == .unknown {
            return "Retomada iniciada no Codex; acompanhando o turno"
        }
        return switch thread.readiness {
        case .executing: "Em execução"
        case .rateLimited: "Interrompida por limite"
        case .awaitingReset: "Aguardando cota"
        case .availableForResume: "Disponível para retomar"
        case .resuming: "Retomando"
        case .completed: "Concluída"
        case .requiresApproval: "Aguardando sua aprovação"
        case .failed: "Falha"
        case .unknown: "Estado desconhecido"
        }
    }

    private var icon: String {
        switch thread.readiness {
        case .rateLimited: "pause.circle.fill"
        case .executing, .resuming: "arrow.trianglehead.2.clockwise.rotate.90"
        case .completed: "checkmark.circle.fill"
        case .requiresApproval: "hand.raised.fill"
        case .failed: "xmark.circle.fill"
        default: "questionmark.circle"
        }
    }

    private var color: Color {
        switch thread.readiness {
        case .rateLimited: .orange
        case .completed: .green
        case .requiresApproval, .failed: .red
        case .executing, .resuming: .blue
        default: .secondary
        }
    }
}

private struct HistoryView: View {
    @EnvironmentObject private var model: SentinelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Histórico de uso").font(.largeTitle.bold())
            Text("Amostras coletadas neste Mac. Sem dados recebidos, o gráfico permanece vazio.").foregroundStyle(.secondary)
            if model.usageHistory.isEmpty {
                ContentUnavailableView("Ainda sem histórico", systemImage: "chart.xyaxis.line", description: Text("As amostras começam depois que o Sentinel consulta o Codex."))
            } else {
                Chart {
                    ForEach(model.usageHistory) { sample in
                        ForEach(sample.windows.filter { $0.usedPercent != nil }) { window in
                            LineMark(x: .value("Horário", sample.timestamp), y: .value("Uso (%)", window.usedPercent!), series: .value("Janela", window.label))
                                .interpolationMethod(.catmullRom)
                            PointMark(x: .value("Horário", sample.timestamp), y: .value("Uso (%)", window.usedPercent!))
                                .foregroundStyle(by: .value("Janela", window.label))
                        }
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(minHeight: 300)
                .padding(16)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                Text("Retenção: até \(model.preferences.historyRetentionDays) dias").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
        .navigationTitle("Histórico")
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var model: SentinelModel

    var body: some View {
        Form {
            Section("Monitoramento") {
                Toggle("Monitorar cotas e conversas", isOn: Binding(get: { model.preferences.monitoringEnabled }, set: model.setMonitoringEnabled))
                Picker("Intervalo de atualização", selection: $model.preferences.refreshIntervalSeconds) {
                    Text("30 segundos").tag(30)
                    Text("1 minuto").tag(60)
                    Text("2 minutos").tag(120)
                    Text("5 minutos").tag(300)
                }
                TextField("Caminho do executável Codex (vazio = PATH)", text: $model.preferences.codexExecutablePath)
                TextField("CODEX_HOME (vazio = padrão)", text: $model.preferences.codexHome)
            }
            Section("Retomada automática") {
                Toggle("Ativar retomada automática", isOn: Binding(get: { model.preferences.autoResumeEnabled }, set: model.setAutoResumeEnabled))
                Text("Quando ativada, vale para todos os chats elegíveis, inclusive fora do período de retenção do painel. Só retomamos uma falha com código de limite confirmado, estado inativo, sem aprovação pendente e cotas conhecidas disponíveis.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Mensagem enviada ao retomar", text: $model.preferences.continuationMessage, axis: .vertical)
                    .lineLimit(3...6)
                Text("Erros transitórios, como uma conversa ainda com writer ativo, são revalidados e tentados novamente com espera progressiva. O Sentinel só inicia quando uma nova leitura confirma o mesmo turno limitado e inativo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacidade e sistema") {
                Toggle("Notificações", isOn: Binding(get: { model.preferences.notificationsEnabled }, set: { value in Task { await model.setNotificationsEnabled(value) } }))
                Toggle("Abrir ao iniciar sessão", isOn: Binding(get: { model.preferences.startAtLogin }, set: model.setStartAtLogin))
                Stepper("Histórico local: \(model.preferences.historyRetentionDays) dias", value: $model.preferences.historyRetentionDays, in: 7...365, step: 7)
                Text("O Sentinel guarda percentuais, IDs de tentativas e preferências localmente. Não armazena conteúdo das conversas, não lê credenciais e não altera a configuração do Codex.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.lastError {
                Section("Estado") { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .navigationTitle("Configurações")
    }
}
