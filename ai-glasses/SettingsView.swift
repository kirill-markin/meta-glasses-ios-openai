//
//  SettingsView.swift
//  ai-glasses
//
//  Created by AI Assistant on 04/01/2026.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai-glasses", category: "SettingsView")

struct SettingsView: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @State private var userPrompt: String = ""
    @State private var selectedMemoryKey: String?
    @State private var showingMemoryEditor = false
    @FocusState private var isUserPromptFocused: Bool
    
    var body: some View {
        NavigationStack {
            Form {
                // User Prompt Section
                Section {
                    TextEditor(text: $userPrompt)
                        .frame(minHeight: 120)
                        .focused($isUserPromptFocused)
                        .onChange(of: userPrompt) { _, newValue in
                            settingsManager.userPrompt = newValue
                        }
                } header: {
                    Text("Additional Instructions")
                } footer: {
                    Text("These instructions will be added to the AI assistant's system prompt.")
                }
                
                // Memories Section
                Section {
                    if settingsManager.memories.isEmpty {
                        Text("No memories yet")
                            .foregroundColor(.secondary)
                            .italic()
                    } else {
                        ForEach(sortedMemoryKeys, id: \.self) { key in
                            MemoryRowView(
                                key: key,
                                value: settingsManager.memories[key] ?? "",
                                onTap: {
                                    selectedMemoryKey = key
                                    showingMemoryEditor = true
                                }
                            )
                        }
                        .onDelete(perform: deleteMemories)
                    }
                    
                    Button(action: addMemory) {
                        Label("Add Memory", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Memories")
                } footer: {
                    Text("The AI can add, update, or delete memories during conversations. You can also manage them here.")
                }
                
                // Info Section
                Section {
                    HStack {
                        Text("Storage Location")
                        Spacer()
                        Text("Documents/settings.json")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    
                    HStack {
                        Text("Total Memories")
                        Spacer()
                        Text("\(settingsManager.memories.count)")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Info")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isUserPromptFocused = false
                    }
                }
            }
            .onAppear {
                userPrompt = settingsManager.userPrompt
            }
            .sheet(isPresented: $showingMemoryEditor) {
                if let key = selectedMemoryKey {
                    MemoryEditorView(
                        originalKey: key,
                        originalValue: settingsManager.memories[key] ?? "",
                        onSave: { newKey, newValue in
                            settingsManager.updateMemory(oldKey: key, newKey: newKey, value: newValue)
                            showingMemoryEditor = false
                            selectedMemoryKey = nil
                        },
                        onCancel: {
                            showingMemoryEditor = false
                            selectedMemoryKey = nil
                        }
                    )
                }
            }
        }
    }
    
    private var sortedMemoryKeys: [String] {
        settingsManager.memories.keys.sorted()
    }
    
    private func addMemory() {
        let newKey = settingsManager.addEmptyMemory()
        selectedMemoryKey = newKey
        showingMemoryEditor = true
    }
    
    private func deleteMemories(at offsets: IndexSet) {
        let keysToDelete = offsets.map { sortedMemoryKeys[$0] }
        for key in keysToDelete {
            settingsManager.deleteMemory(key: key)
        }
    }
}

// MARK: - Memory Row View

private struct MemoryRowView: View {
    let key: String
    let value: String
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(key)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    if !value.isEmpty {
                        Text(value)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Memory Editor View

private struct MemoryEditorView: View {
    let originalKey: String
    let originalValue: String
    let onSave: (String, String) -> Void
    let onCancel: () -> Void
    
    @State private var key: String = ""
    @State private var value: String = ""
    @FocusState private var focusedField: Field?
    
    private enum Field {
        case key
        case value
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Key", text: $key)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .key)
                } header: {
                    Text("Key")
                } footer: {
                    Text("A short identifier for this memory (e.g., 'user_name', 'favorite_color')")
                }
                
                Section {
                    TextEditor(text: $value)
                        .frame(minHeight: 100)
                        .focused($focusedField, equals: .value)
                } header: {
                    Text("Value")
                } footer: {
                    Text("The information to remember")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(originalKey.starts(with: "new_memory") ? "New Memory" : "Edit Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(key, value)
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
            .onAppear {
                key = originalKey
                value = originalValue
            }
        }
    }
}

#Preview {
    SettingsView()
}
