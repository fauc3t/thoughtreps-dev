import SwiftUI

/// Wheel picker for a custom interval (count and unit). Reports the chosen whole days on Done.
struct IntervalPickerSheet: View {
    let onDone: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var duration: IntervalDuration

    init(initialDays: Int, onDone: @escaping (Int) -> Void) {
        _duration = State(initialValue: IntervalDuration(days: initialDays))
        self.onDone = onDone
    }

    private var countBinding: Binding<Int> {
        Binding(
            get: { duration.count },
            set: { duration = IntervalDuration(unit: duration.unit, count: $0) }
        )
    }

    private var unitBinding: Binding<IntervalDuration.Unit> {
        Binding(
            get: { duration.unit },
            set: { duration = duration.with(unit: $0) }
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Comes back every \(duration.phrase)")
                    .font(.headline)
                    .padding(.top, 8)
                HStack(spacing: 0) {
                    Picker("Count", selection: countBinding) {
                        ForEach(duration.unit.counts, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .pickerStyle(.wheel)
                    Picker("Unit", selection: unitBinding) {
                        ForEach(IntervalDuration.Unit.allCases, id: \.self) { unit in
                            Text(unit.name(count: duration.count)).tag(unit)
                        }
                    }
                    .pickerStyle(.wheel)
                }
            }
            .navigationTitle("Custom interval")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(duration.days)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.height(320)])
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        IntervalPickerSheet(initialDays: 5) { _ in }
    }
}
