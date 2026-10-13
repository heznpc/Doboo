import SwiftUI

struct TaskDashboard: View {
  @Bindable var connection: TaskConnection
  @Bindable var library: CharacterLibrary
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showConnection = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          let current = connection.tasks.first
          let character = current.map { task in library.packs.first { $0.id == task.character.id && $0.version == task.character.version } } ?? library.selected
          HStack {
            TimelineView(.animation(minimumInterval: 0.15, paused: reduceMotion || scenePhase != .active)) { time in
              if let character {
              PackCharacterView(pack: character.watchRepresentation, interaction: BlobInteractionState(), phase: time.date.timeIntervalSinceReferenceDate,
                motionEnabled: !reduceMotion && scenePhase == .active, taskStatus: current?.status)
                .frame(width: 64, height: 70)
                .opacity(current?.status == "interrupted" ? 0.55 : 1)
              } else { Image(systemName: "person.crop.circle.badge.questionmark").frame(width: 64, height: 70).accessibilityLabel("이 버전의 캐릭터를 가져와 주세요") }
            }
            VStack(alignment: .leading) {
              Text(current?.character.name ?? library.selected.name).font(.headline).lineLimit(2)
              Text(connection.project.isEmpty ? "컴퓨터 연결" : connection.project).font(.caption)
              Text(connection.connected ? "연결됨" : "연결 확인 필요").font(.caption).foregroundStyle(.secondary)
            }
          }
          #if os(iOS)
          TextField("Doboo에게 시킬 작업", text: $connection.prompt, axis: .vertical)
            .lineLimit(3...7).textFieldStyle(.roundedBorder).accessibilityIdentifier("task.prompt")
            .disabled(connection.pendingRetry)
          Button(connection.pendingRetry ? "같은 요청 다시 확인" : "작업 부탁하기") { Task { await connection.submit(character: library.selected) } }
            .buttonStyle(.borderedProminent).disabled((!connection.canSubmit && !connection.pendingRetry) || connection.submitting)
            .accessibilityIdentifier("task.submit")
          #endif
          if let task = current {
            HStack {
              Image(systemName: task.status == "completed" ? "checkmark.circle.fill" : task.status == "needsApproval" ? "hand.raised.fill" : "circle.dotted")
              Text(task.label).font(.headline).accessibilityIdentifier("task.status")
              if !task.finished && task.status != "needsApproval" { ProgressView() }
            }
            #if os(iOS)
            Text(task.prompt).font(.subheadline)
            #endif
            if !task.finished { Text(task.activity).font(.caption).foregroundStyle(.secondary) }
            ForEach(task.approvals) { approval in
              Text(approval.description).font(.caption)
              #if os(iOS)
              HStack {
                Button("이번 작업 허용") { Task { await connection.approve(task, approval: approval, accept: true) } }
                Button("거절", role: .destructive) { Task { await connection.approve(task, approval: approval, accept: false) } }
              }
              #else
              Text("폰에서 승인 내용을 확인해 주세요.").font(.caption)
              #endif
            }
            if !task.result.isEmpty {
              #if os(watchOS)
              Text(task.result.components(separatedBy: "\n\n").first ?? task.result)
                .font(.caption2).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("task.result")
              NavigationLink("결과 자세히") { ScrollView { Text(task.result).font(.caption2).padding() } }
              #else
              Text(task.result).accessibilityIdentifier("task.result")
              #endif
            }
            #if os(watchOS)
            NavigationLink("부탁한 내용") { ScrollView { Text(task.prompt).font(.caption).padding() } }
            #endif
            if let error = task.error { Text(error).foregroundStyle(.red) }
            if !task.finished { Button("작업 중단", role: .destructive) { Task { await connection.cancel(task) } } }
            #if os(iOS)
            if !task.commands.isEmpty {
              DisclosureGroup("컴퓨터 실행 기록 \(task.commands.count)개") {
                ForEach(Array(task.commands.enumerated()), id: \.offset) { _, command in
                  Text(command.command).font(.caption.monospaced())
                  Text("종료 코드: \(command.exitCode.map(String.init) ?? "실행 중")").font(.caption)
                  Text(command.output).font(.caption.monospaced()).textSelection(.enabled)
                }
              }
            }
            #endif
          } else { Text("부탁한 작업과 결과가 여기에 표시됩니다.").foregroundStyle(.secondary) }
          if let error = connection.error { Text(error).font(.caption).foregroundStyle(.red) }
          Button("컴퓨터 연결 설정") { showConnection = true }.font(.caption)
        }.padding()
      }
      .navigationTitle("Doboo 작업")
      #if os(watchOS)
      .font(.caption)
      #endif
      .sheet(isPresented: $showConnection) {
        NavigationStack {
          Form {
            TextField("컴퓨터 주소", text: $connection.address).textContentType(.URL)
            SecureField("연결 키", text: $connection.connectionToken)
            Button("연결") { Task { await connection.connect(); if connection.connected { showConnection = false } } }
            if let error = connection.error { Text(error).foregroundStyle(.red) }
          }.navigationTitle("컴퓨터 연결")
        }
      }
      .task(id: scenePhase) {
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
          await connection.refresh()
          do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
      }
    }
  }
}
