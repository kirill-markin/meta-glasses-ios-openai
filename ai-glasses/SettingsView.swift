//
//  SettingsView.swift
//  ai-glasses
//
//  Created by AI Assistant on 04/01/2026.
//

import SwiftUI
import UIKit
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai-glasses", category: "SettingsView")

// MARK: - Custom TextView (avoids SwiftUI TextEditor frame bugs)

private struct CustomTextView: UIViewRepresentable {
    @Binding var text: String
    
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.delegate = context.coordinator
        textView.isScrollEnabled = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        return textView
    }
    
    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }
    
    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        
        init(text: Binding<String>) {
            _text = text
        }
        
        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
        
        func textViewDidBeginEditing(_ textView: UITextView) {
            // Place cursor at the end
            let endPosition = textView.endOfDocument
            textView.selectedTextRange = textView.textRange(from: endPosition, to: endPosition)
        }
    }
}

// MARK: - Settings View (Main Menu)

struct SettingsView: View {
    @ObservedObject var glassesManager: GlassesManager
    
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
    
    var body: some View {
        NavigationStack {
            Form {
                // Main Settings
                Section {
                    NavigationLink {
                        AdditionalInstructionsView()
                    } label: {
                        Label("Additional Instructions", systemImage: "text.quote")
                    }
                    
                    NavigationLink {
                        MemoriesListView()
                    } label: {
                        Label("Memories", systemImage: "brain")
                    }
                }
                
                // Developer Section
                Section {
                    NavigationLink {
                        GlassesTab(glassesManager: glassesManager)
                    } label: {
                        Label("Glasses", systemImage: "eyeglasses")
                    }
                } header: {
                    Text("Developer")
                }
                
                // App Info
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Build")
                        Spacer()
                        Text(buildNumber)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

// MARK: - Additional Instructions View

private struct AdditionalInstructionsView: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @State private var text: String = ""
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        CustomTextView(text: $text)
            .padding()
            .navigationTitle("Additional Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        settingsManager.userPrompt = text
                        settingsManager.saveNow()
                        dismiss()
                    }
                }
            }
            .onAppear {
                text = settingsManager.userPrompt
            }
    }
}

// MARK: - Memories List View

private struct MemoriesListView: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @State private var selectedMemoryKey: String?
    
    private var sortedMemoryKeys: [String] {
        settingsManager.memories.keys.sorted()
    }
    
    var body: some View {
        Form {
            if settingsManager.memories.isEmpty {
                Section {
                    Text("No memories yet")
                        .foregroundColor(.secondary)
                        .italic()
                } footer: {
                    Text("The AI can add memories during conversations, or you can add them manually.")
                }
            } else {
                Section {
                    ForEach(sortedMemoryKeys, id: \.self) { key in
                        NavigationLink {
                            MemoryEditorView(
                                memoryKey: key,
                                onDelete: {
                                    settingsManager.deleteMemory(key: key)
                                }
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(key)
                                    .font(.headline)
                                
                                if let value = settingsManager.memories[key], !value.isEmpty {
                                    Text(value)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    .onDelete(perform: deleteMemories)
                }
            }
            
            Section {
                Button(action: addMemory) {
                    Label("Add Memory", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle("Memories")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedMemoryKey) { key in
            MemoryEditorView(
                memoryKey: key,
                onDelete: {
                    settingsManager.deleteMemory(key: key)
                    selectedMemoryKey = nil
                }
            )
        }
    }
    
    private func addMemory() {
        let newKey = settingsManager.addEmptyMemory()
        selectedMemoryKey = newKey
    }
    
    private func deleteMemories(at offsets: IndexSet) {
        let keysToDelete = offsets.map { sortedMemoryKeys[$0] }
        for key in keysToDelete {
            settingsManager.deleteMemory(key: key)
        }
    }
}

// MARK: - Memory Editor View

private struct MemoryEditorView: View {
    let memoryKey: String
    let onDelete: () -> Void
    
    @ObservedObject private var settingsManager = SettingsManager.shared
    @State private var key: String = ""
    @State private var value: String = ""
    @State private var showingDeleteConfirmation = false
    @Environment(\.dismiss) private var dismiss
    
    private var isNewMemory: Bool {
        memoryKey.starts(with: "new_memory")
    }
    
    var body: some View {
        Form {
            Section {
                TextField("Key", text: $key)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            } header: {
                Text("Key")
            } footer: {
                Text("A short identifier (e.g., 'user_name', 'favorite_color')")
            }
            
            Section {
                CustomTextView(text: $value)
                    .frame(height: 150)
            } header: {
                Text("Value")
            }
            
            if !isNewMemory {
                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete Memory", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(isNewMemory ? "New Memory" : "Edit Memory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    settingsManager.updateMemory(oldKey: memoryKey, newKey: key, value: value)
                    dismiss()
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .confirmationDialog("Delete this memory?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                onDelete()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            key = memoryKey
            value = settingsManager.memories[memoryKey] ?? ""
        }
    }
}

#Preview {
    SettingsView(glassesManager: GlassesManager())
}
