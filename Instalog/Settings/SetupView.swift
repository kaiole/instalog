import InstalogCore
import SwiftUI

/// Sections and their meals, top to bottom as the day runs. Drag handles reorder; VoiceOver
/// gets Move up / Move down actions.
struct SetupView: View {
    let model: DiaryModel
    /// Set when shown as its own sheet; nil when pushed from Settings.
    let close: (() -> Void)?
    @State private var addingSection = false
    @State private var newSectionName = ""
    @State private var removing: RoutineSection?
    @State private var editMode: EditMode = .inactive

    var body: some View {
        List {
            SwiftUI.Section {
                Text("Top to bottom is your day. Each day opens on the first section, and each section opens on its first meal. Tap Reorder to drag. Past logs don’t change.")
                    .font(Typeface.sans(14))
                    .foregroundStyle(Palette.secondary)
                    .listRowBackground(Color.clear)
            }
            SwiftUI.Section {
                ForEach(Array(model.activeSections.enumerated()), id: \.element.id) { index, section in
                    NavigationLink {
                        SectionMealsView(model: model, sectionID: section.id)
                    } label: {
                        HStack(spacing: 10) {
                            Text(String(format: "%02d", index + 1)).font(Typeface.mono(12)).foregroundStyle(Palette.tertiary)
                            Text(section.name).font(Typeface.sans(17, .semibold))
                            Spacer()
                            Text(mealCountText(section)).font(Typeface.mono(12)).foregroundStyle(Palette.tertiary)
                        }
                        .frame(minHeight: 44)
                    }
                    .listRowBackground(Palette.raised)
                    .accessibilityAction(named: "Move up") { move(index, by: -1) }
                    .accessibilityAction(named: "Move down") { move(index, by: 1) }
                    .swipeActions(allowsFullSwipe: false) {
                        Button("Remove", role: .destructive) { removing = section }
                    }
                }
                .onMove { source, destination in
                    Task { await run { try await model.moveSections(from: source, to: destination) } }
                }
                Button {
                    newSectionName = ""
                    addingSection = true
                } label: {
                    Label("New section", systemImage: "plus").font(Typeface.sans(15, .semibold))
                }
                .foregroundStyle(Palette.accent)
                .listRowBackground(Palette.raised)
            } header: {
                Caption("Sections")
            } footer: {
                if model.activeSections.isEmpty {
                    Text("Sections are optional. Without them you get one daily log with all your saved meals.")
                }
            }
            SwiftUI.Section {
                NavigationLink {
                    MealLibraryView(model: model)
                } label: {
                    HStack {
                        Text("Saved meals").font(Typeface.sans(15, .medium))
                        Spacer()
                        Text("\(model.activeMeals.count)").font(Typeface.mono(13)).foregroundStyle(Palette.tertiary)
                    }
                    .frame(minHeight: 44)
                }
                .listRowBackground(Palette.raised)
            } header: {
                Caption("Library")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.sheet)
        .environment(\.editMode, $editMode)
        .navigationTitle("Sections & meals")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? "Done reordering" : "Reorder") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
            }
            if let close {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: close).fontWeight(.semibold) }
            }
        }
        .alert("New section", isPresented: $addingSection) {
            TextField("Name, e.g. Post-workout", text: $newSectionName)
            Button("Add") { Task { await run { try await model.addSection(named: newSectionName) } } }
                .disabled(newSectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Remove \(removing?.name ?? "section")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove section", role: .destructive) {
                if let id = removing?.id { Task { await run { try await model.removeSection(id: id) } } }
            }
        } message: {
            Text("Entries already logged here stay in your history under this name. Saved meals aren’t deleted.")
        }
        .foregroundStyle(Palette.text)
    }

    private func mealCountText(_ section: RoutineSection) -> String {
        let count = MealSelection.usesFallback(section, activeMeals: model.activeMeals) ? 0 : section.mealIDs.count
        return count == 0 ? "all meals" : "\(count) meal\(count == 1 ? "" : "s")"
    }

    private func move(_ index: Int, by step: Int) {
        let target = index + step
        guard model.activeSections.indices.contains(target) else { return }
        Task { await run { try await model.moveSections(from: [index], to: step > 0 ? target + 1 : target) } }
    }

    private func run(_ action: () async throws -> Void) async {
        do { try await action() } catch { model.errorMessage = "Couldn’t save that change. \(error.localizedDescription)" }
    }
}

/// One section: its name and its ordered meal selection.
struct SectionMealsView: View {
    let model: DiaryModel
    let sectionID: UUID
    @State private var name = ""
    @State private var picking = false

    private var section: RoutineSection? { model.sections.first { $0.id == sectionID } }

    var body: some View {
        let meals = (section?.mealIDs ?? []).compactMap { id in model.activeMeals.first { $0.id == id } }
        List {
            SwiftUI.Section {
                TextField("Section name", text: $name)
                    .font(Typeface.sans(17, .semibold))
                    .submitLabel(.done)
                    .onSubmit(rename)
                    .listRowBackground(Palette.raised)
            } header: {
                Caption("Name")
            }
            SwiftUI.Section {
                if meals.isEmpty {
                    Text("No meals assigned, so \(section?.name ?? "this section") shows all your saved meals.")
                        .font(Typeface.sans(13))
                        .foregroundStyle(Palette.secondary)
                        .listRowBackground(Palette.raised)
                }
                ForEach(Array(meals.enumerated()), id: \.element.id) { index, meal in
                    HStack {
                        Text(meal.name).font(Typeface.sans(15, .medium))
                        Spacer()
                        if index == 0 {
                            Text("Opens first")
                                .font(Typeface.sans(11, .semibold))
                                .foregroundStyle(Palette.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.accentBorder))
                        }
                    }
                    .frame(minHeight: 44)
                    .listRowBackground(Palette.raised)
                    .accessibilityAction(named: "Move up") { reorder(meals, from: index, by: -1) }
                    .accessibilityAction(named: "Move down") { reorder(meals, from: index, by: 1) }
                }
                .onMove { source, destination in
                    save(meals.map(\.id).moving(fromOffsets: source, toOffset: destination))
                }
                .onDelete { offsets in
                    save(meals.enumerated().filter { !offsets.contains($0.offset) }.map(\.element.id))
                }
                Button {
                    picking = true
                } label: {
                    Label("Add a meal to \(section?.name ?? "section")", systemImage: "plus").font(Typeface.sans(14, .semibold))
                }
                .foregroundStyle(Palette.accent)
                .listRowBackground(Palette.raised)
            } header: {
                Caption("Meals, in order")
            } footer: {
                Text("A meal can sit in more than one section. Logging never reorders this list.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.sheet)
        .environment(\.editMode, .constant(.active))
        .navigationTitle(section?.name ?? "Section")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = section?.name ?? "" }
        .onDisappear(perform: rename)
        .sheet(isPresented: $picking) {
            MealPickerSheet(model: model, sectionID: sectionID, close: { picking = false })
                .presentationDetents([.medium, .large])
                .presentationBackground(Palette.sheet)
        }
        .foregroundStyle(Palette.text)
    }

    private func rename() {
        guard let section else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // A blank name isn't saved; put the current one back so the field never shows empty.
        guard !trimmed.isEmpty else {
            name = section.name
            return
        }
        guard trimmed != section.name else { return }
        Task {
            do { try await model.renameSection(id: sectionID, to: trimmed) } catch {
                model.errorMessage = "Couldn’t rename the section. \(error.localizedDescription)"
            }
        }
    }

    private func reorder(_ meals: [MealTemplate], from index: Int, by step: Int) {
        let target = index + step
        guard meals.indices.contains(target) else { return }
        save(meals.map(\.id).moving(fromOffsets: [index], toOffset: step > 0 ? target + 1 : target))
    }

    private func save(_ ids: [UUID]) {
        Task {
            do { try await model.setMeals(ids, forSection: sectionID) } catch {
                model.errorMessage = "Couldn’t save the meal order. \(error.localizedDescription)"
            }
        }
    }
}

struct MealPickerSheet: View {
    let model: DiaryModel
    let sectionID: UUID
    let close: () -> Void

    var body: some View {
        let section = model.sections.first { $0.id == sectionID }
        let available = model.activeMeals.filter { !(section?.mealIDs.contains($0.id) ?? false) }
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                SheetHeader(title: "Add to \(section?.name ?? "section")", close: close)
                Text("New picks go to the bottom of the list.")
                    .font(Typeface.sans(13))
                    .foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
                if available.isEmpty {
                    Text(model.activeMeals.isEmpty ? "No saved meals yet." : "Every saved meal is already in this section.")
                        .font(Typeface.sans(14))
                        .foregroundStyle(Palette.secondary)
                }
                ForEach(available) { meal in
                    Button {
                        Task {
                            do {
                                try await model.setMeals((section?.mealIDs ?? []) + [meal.id], forSection: sectionID)
                                close()
                            } catch {
                                model.errorMessage = "Couldn’t add “\(meal.name)”. \(error.localizedDescription)"
                            }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meal.name).font(Typeface.sans(15, .semibold))
                                let others = model.sections(containing: meal.id).map(\.name)
                                Text(others.isEmpty ? "Not in any section yet" : "Also in \(others.joined(separator: ", "))")
                                    .font(Typeface.sans(12))
                                    .foregroundStyle(Palette.tertiary)
                            }
                            Spacer()
                            Image(systemName: "plus").foregroundStyle(Palette.accent)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 56)
                        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .padding(.top, 8)
        }
        .foregroundStyle(Palette.text)
    }
}
