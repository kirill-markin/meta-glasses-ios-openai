//
//  ThreadsView.swift
//  ai-glasses
//
//  Thread history list and detail views
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai-glasses", category: "ThreadsView")

// MARK: - Threads List View

struct ThreadsView: View {
    @ObservedObject private var threadsManager = ThreadsManager.shared
    let onContinueThread: () -> Void
    
    init(onContinueThread: @escaping () -> Void = {}) {
        self.onContinueThread = onContinueThread
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if threadsManager.threads.isEmpty {
                    EmptyThreadsView()
                } else {
                    ThreadsListContent(
                        threads: threadsManager.threads,
                        onDelete: { thread in
                            threadsManager.deleteThread(id: thread.id)
                        },
                        onContinue: onContinueThread
                    )
                }
            }
            .navigationTitle("Threads")
        }
    }
}

// MARK: - Empty State

private struct EmptyThreadsView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            VStack(spacing: 8) {
                Text("No Conversations Yet")
                    .font(.title2.bold())
                
                Text("Start a discussion in the Voice Agent tab\nto see your conversation history here.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Threads List Content

private struct ThreadsListContent: View {
    let threads: [ConversationThread]
    let onDelete: (ConversationThread) -> Void
    let onContinue: () -> Void
    
    var body: some View {
        List {
            ForEach(threads) { thread in
                NavigationLink(value: thread) {
                    ThreadRow(thread: thread)
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    onDelete(threads[index])
                }
            }
        }
        .listStyle(.plain)
        .navigationDestination(for: ConversationThread.self) { thread in
            ThreadDetailView(
                threadId: thread.id,
                onDelete: {
                    onDelete(thread)
                },
                onContinue: onContinue
            )
        }
    }
}

// MARK: - Thread Row

private struct ThreadRow: View {
    let thread: ConversationThread
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(thread.title)
                .font(.headline)
                .lineLimit(1)
            
            HStack(spacing: 12) {
                Label("\(thread.messages.count)", systemImage: "bubble.left.and.bubble.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(formatDate(thread.updatedAt))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Thread Detail View

struct ThreadDetailView: View {
    let threadId: UUID
    let onDelete: () -> Void
    let onContinue: () -> Void
    
    @ObservedObject private var threadsManager = ThreadsManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false
    @State private var copiedMessageId: UUID?
    @State private var showFullTitle = false
    
    private var thread: ConversationThread? {
        threadsManager.thread(id: threadId)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if let thread = thread {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(thread.messages) { message in
                            ThreadMessageBubble(
                                message: message,
                                isCopied: copiedMessageId == message.id,
                                onCopy: {
                                    copyToClipboard(message.text)
                                    copiedMessageId = message.id
                                    // Reset copied state after delay
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        if copiedMessageId == message.id {
                                            copiedMessageId = nil
                                        }
                                    }
                                }
                            )
                        }
                    }
                    .padding()
                }
                
                // Continue button at bottom
                VStack(spacing: 0) {
                    Divider()
                    Button(action: {
                        threadsManager.pendingContinuationThreadId = threadId
                        onContinue()
                        dismiss()
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: "play.fill")
                            Text("Continue Discussion")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .padding()
                }
                .background(Color(.systemBackground))
            } else {
                Text("Thread not found")
                    .foregroundColor(.secondary)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button(action: {
                    showFullTitle = true
                }) {
                    Text(thread?.title ?? "Thread")
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundColor(.primary)
                }
                .popover(isPresented: $showFullTitle) {
                    Text(thread?.title ?? "Thread")
                        .font(.body)
                        .padding()
                        .presentationCompactAdaptation(.popover)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(role: .destructive, action: {
                        showDeleteConfirmation = true
                    }) {
                        Label("Delete Thread", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "Delete this thread?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                onDelete()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }
    
    private func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
        logger.info("📋 Copied message to clipboard")
    }
}

// MARK: - Thread Message Bubble

private struct ThreadMessageBubble: View {
    let message: StoredMessage
    let isCopied: Bool
    let onCopy: () -> Void
    
    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 40) }
            
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: message.isUser ? "person.fill" : "sparkles")
                        .font(.caption)
                        .foregroundColor(message.isUser ? .blue : .purple)
                    Text(message.isUser ? "You" : "Assistant")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    
                    Text(formatTime(message.timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                
                Text(message.text)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isUser ? Color.blue.opacity(0.2) : Color.purple.opacity(0.2))
                    .cornerRadius(12)
                    .overlay(alignment: .topTrailing) {
                        if isCopied {
                            Text("Copied!")
                                .font(.caption2.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green)
                                .cornerRadius(4)
                                .offset(x: 4, y: -8)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: isCopied)
                    .onLongPressGesture {
                        onCopy()
                    }
            }
            
            if !message.isUser { Spacer(minLength: 40) }
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

#Preview {
    ThreadsView()
}
