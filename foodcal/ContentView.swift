import SwiftUI
import Combine
import Network

// Main app structure
struct FoodRecommendationApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// Main view
struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel()
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack {
            // App header
            Text("Food Finder")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.top) // Adjusted padding

            // Network status indicator
            if !viewModel.isConnected {
                Text("No Internet Connection")
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.red)
                    .cornerRadius(8)
                    .padding(.bottom, 5) // Add some space below
            }

            // Chat messages display
            ScrollViewReader { scrollView in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageView(message: message)
                                .id(message.id) // Ensure each message has a unique ID for potential targeting
                        }
                    }
                    .padding()
                    // Make the scroll content area take up available space
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                }
                .id("MessageScrollView") // Give the ScrollView an ID for potential targeting
                .onChange(of: viewModel.messages.count) { _, newCount in
                    // Scroll to the last message when count changes
                    if let lastMessageId = viewModel.messages.last?.id {
                        DispatchQueue.main.async { // Ensure UI updates on main thread
                            withAnimation {
                                scrollView.scrollTo(lastMessageId, anchor: .bottom)
                            }
                        }
                    }
                }
                // Give ScrollView a flexible frame
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGray6))
                // Add tap gesture to dismiss keyboard
                .onTapGesture {
                    isTextFieldFocused = false
                }
            }

            // Input field and send button
            HStack {
                TextField("Ask about food...", text: $viewModel.inputText, axis: .vertical) // Allow vertical expansion
                    .lineLimit(1...5) // Limit lines for text field
                    .padding(10)
                    .background(Color(.systemGray5))
                    .cornerRadius(12)
                    .focused($isTextFieldFocused)
                    // Submit on return key
                    .onSubmit {
                        viewModel.prepareSendMessage()
                        // isTextFieldFocused = false // Focus is lost automatically on submit
                    }

                Button(action: {
                    viewModel.prepareSendMessage() // Use the preparation method
                    isTextFieldFocused = false
                }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(viewModel.canSendMessage ? .blue : .gray) // Updated condition
                }
                .disabled(!viewModel.canSendMessage) // Updated condition
            }
            .padding()
        }
        // *** Add the alert modifier here ***
        .alert("Internet Access Required", isPresented: $viewModel.showInternetInfoAlert) {
            Button("OK") {
                // User acknowledged, set the flag and try sending again if needed
                viewModel.acknowledgeInternetUse()
                // Decide if we should automatically send the message the user was trying to send
                // Let's trigger send explicitly IF there's text waiting
                if !viewModel.inputText.isEmpty || viewModel.isWaitingForAcknowledgement {
                    viewModel.sendMessageAfterAcknowledgement()
                }
            }
            Button("Cancel", role: .cancel) {
                 viewModel.cancelAcknowledgementWait() // Reset waiting state if cancelled
            }
        } message: {
            Text("Food Finder needs access to the internet to fetch recommendations and recipes. Please ensure you are connected.")
        }
    }
}

// Message view
struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isUser {
                Spacer()
            }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .padding(12)
                    .background(message.isUser ? Color.blue : Color(.systemGray4))
                    .foregroundColor(message.isUser ? .white : .primary)
                    .cornerRadius(16)
                    // Ensure text wraps within the bubble
                    .fixedSize(horizontal: false, vertical: true)
                    // Add context menu for copying
                    .contextMenu {
                          Button {
                              UIPasteboard.general.string = message.content
                          } label: {
                              Label("Copy", systemImage: "doc.on.doc")
                          }
                      }
            }
            // Limit the width of the message bubble
            .frame(maxWidth: UIScreen.main.bounds.width * 0.75, alignment: message.isUser ? .trailing : .leading) // Slightly wider max
            .padding(.horizontal, 8)
            .padding(.vertical, 4)


            if !message.isUser {
                Spacer()
            }
        }
    }
}


// Message model
struct ChatMessage: Identifiable, Equatable { // Add Equatable for easier checking
    let id = UUID()
    let content: String
    let isUser: Bool
    let timestamp = Date()

    // Implement Equatable based on ID or content+timestamp if needed for more complex checks
     static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
         lhs.id == rhs.id
     }
}

// ViewModel to handle chat logic
class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isConnected = true
    @Published var showInternetInfoAlert = false // State for showing the alert
    @Published var isWaitingForAcknowledgement = false // Track if we showed alert and are waiting for OK

    // Use AppStorage to remember acknowledgement
    @AppStorage("hasAcknowledgedInternetUse") private var hasAcknowledgedInternetUse = false

    private var cancellables = Set<AnyCancellable>()
    private var waitingForCalories = false
    private var currentQuery = ""
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private var pendingTextToSend: String? // Store text while waiting for acknowledgement


    // Computed property to centralize send button logic
    var canSendMessage: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isConnected
    }

    init() {
        setupNetworkMonitoring()
        // Add initial message only if messages array is empty
        if messages.isEmpty {
             addSystemMessage("Welcome to Food Finder! What kind of food would you like recommendations for today?")
        }
    }

    deinit {
        monitor.cancel()
    }

    private func setupNetworkMonitoring() {
        // Ensure the monitor starts detecting immediately
        monitor.start(queue: queue)
        monitor.pathUpdateHandler = { [weak self] path in
             DispatchQueue.main.async {
                guard let self = self else { return }
                let previouslyConnected = self.isConnected
                let currentlyConnected = path.status == .satisfied
                self.isConnected = currentlyConnected

                if !currentlyConnected && previouslyConnected {
                    if self.messages.last?.content != "Network connection appears to be offline." {
                        self.addSystemMessage("Network connection appears to be offline.")
                    }
                } else if currentlyConnected && !previouslyConnected {
                    // Check if the last message indicates offline status or if messages are empty
                    if self.messages.last?.content == "Network connection appears to be offline." || self.messages.isEmpty {
                        // Only show restored if it was previously offline or just starting up connected
                        if self.messages.last?.content != "Network connection restored." {
                            self.addSystemMessage("Network connection restored.")
                        }
                    }
                }
             }
        }
        // Set initial state based on current path right after starting
         DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.isConnected = self?.monitor.currentPath.status == .satisfied
         }
    }

    // Add a message from the system
    func addSystemMessage(_ content: String) {
        let message = ChatMessage(content: content, isUser: false)
        DispatchQueue.main.async {
            // Avoid adding duplicate system messages consecutively
            if self.messages.last?.content != message.content || self.messages.last?.isUser == true {
                self.messages.append(message)
            }
        }
    }

    // Add a message from the user
    func addUserMessage(_ content: String) {
        let message = ChatMessage(content: content, isUser: true)
        DispatchQueue.main.async {
            self.messages.append(message)
        }
    }

     // Function to prepare sending, checks for acknowledgement
    func prepareSendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return } // Don't send empty messages

        // Check connection *before* asking for acknowledgement or sending
        guard isConnected else {
             if self.messages.last?.content != "Network connection appears to be offline." {
                 self.addSystemMessage("Network connection appears to be offline. Please check your connection and try again.")
             }
             return
        }


        // If internet use hasn't been acknowledged, show the alert first
        if !hasAcknowledgedInternetUse {
             pendingTextToSend = text // Store the text
             isWaitingForAcknowledgement = true // Set flag
            showInternetInfoAlert = true
            return // Wait for alert response
        }

        // If acknowledged and connected, proceed directly
        sendMessage(text: text)
    }

    // Function called by the Alert's OK button
    func acknowledgeInternetUse() {
        hasAcknowledgedInternetUse = true
        showInternetInfoAlert = false // Hide the alert
        // isWaitingForAcknowledgement remains true until sendMessageAfterAcknowledgement is called or cancelled
    }

     // Called when user cancels the alert
     func cancelAcknowledgementWait() {
         isWaitingForAcknowledgement = false
         pendingTextToSend = nil
     }

     // Called after OK is tapped on the alert, proceeds with stored text
     func sendMessageAfterAcknowledgement() {
         guard isWaitingForAcknowledgement, let text = pendingTextToSend else {
             isWaitingForAcknowledgement = false // Ensure flag is reset
             pendingTextToSend = nil
             return
         }
         isWaitingForAcknowledgement = false // Reset flag
         pendingTextToSend = nil
         sendMessage(text: text) // Send the stored text
     }


    // Process user input and send message (now takes text as parameter)
    private func sendMessage(text: String) {
        // Ensure acknowledgement happened and we are connected
        guard hasAcknowledgedInternetUse && isConnected else {
            print("Error: Attempted to send message without internet acknowledgement or connection.")
            // Show connection error if applicable
             if !isConnected && self.messages.last?.content != "Network connection appears to be offline." {
                 self.addSystemMessage("Network connection appears to be offline.")
             } else if !hasAcknowledgedInternetUse {
                 // This case should ideally be prevented by prepareSendMessage, but handle defensively
                 pendingTextToSend = text
                 isWaitingForAcknowledgement = true
                 showInternetInfoAlert = true
             }
            return
        }

        // Add user message and clear input field
        addUserMessage(text)
        inputText = ""

        // Use the passed 'text' for processing
        let textToSend = text

        if waitingForCalories {
            waitingForCalories = false
            let calorieInfo = textToSend
            addSystemMessage("Searching for food recommendations based on your preferences and calorie needs...")

            let fullPrompt = """
            The user is looking for food recommendations like "\(currentQuery)".
            They specified a target of approximately \(calorieInfo) calories for the meal.

            Please provide 3 to 5 distinct food recommendations that fit these criteria.
            For each recommendation:
            1.  Provide a clear heading (e.g., using **Dish Name**).
            2.  Briefly describe the dish and why it fits the request (especially calorie count if possible).
            3.  List the main ingredients using bullet points (* Ingredient).
            4.  Provide concise recipe steps using numbered points (1. Step).
            Keep the response well-formatted and easy to read in a chat interface.
            """


            fetchGeminiResponse(prompt: fullPrompt)
        } else {
            currentQuery = textToSend
            waitingForCalories = true
            addSystemMessage("Sounds delicious! Roughly how many calories are you aiming for in this meal? (e.g., 500)")
        }
    }

    // Call Gemini API
    private func fetchGeminiResponse(prompt: String) {
        // --- IMPORTANT SECURITY WARNING ---
        // NEVER embed API keys directly in client-side code like this.
        // Use a backend server or secure configuration service.
        // *** UPDATED API KEY ***
        let apiKey = "AIzaSyAMDe_zuK2On_HbeqB0-yxN7pidP3WE2c0" // <-- Your actual API key
        
        // *** UPDATED GUARD CHECK ***
        // Now only checks if the key is empty.
        guard !apiKey.isEmpty else {
             addSystemMessage("API Key is missing. Please add it to the ChatViewModel.") // Updated message
             return
        }
        // --- END SECURITY WARNING ---

        // *** Use a known available model like gemini-1.5-pro-latest ***
        let modelName = "gemini-1.5-pro-latest" // Changed from gemini-pro

        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent?key=\(apiKey)") else {
            addSystemMessage("Error: Unable to create API URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.7,
                "topK": 40,
                "topP": 0.95,
                "maxOutputTokens": 1536 // Increased slightly for potentially longer recipes
                // Consider adding stopSequences if needed
            ]
             // Add safetySettings to block harmful content (adjust thresholds as needed)
             // ,
             // "safetySettings": [
             //     ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_MEDIUM_AND_ABOVE"],
             //     ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_MEDIUM_AND_ABOVE"],
             //     ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_MEDIUM_AND_ABOVE"],
             //     ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_MEDIUM_AND_ABOVE"]
             // ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody, options: .prettyPrinted) // Use prettyPrinted for debug logging if needed
             // Log the request body for debugging
             // if let jsonString = String(data: request.httpBody!, encoding: .utf8) { print("Request Body JSON: \(jsonString)") }
        } catch {
            addSystemMessage("Error: Unable to prepare API request payload. \(error.localizedDescription)")
            return
        }

        addSystemMessage("...") // Indicate loading / thinking

        print("Sending request to Gemini API (Model: \(modelName))...")
        // print("Prompt: \(prompt)") // Logging the full prompt can be verbose

        URLSession.shared.dataTaskPublisher(for: request)
            .map(\.data)
            .handleEvents(receiveOutput: { data in
                 if let jsonString = String(data: data, encoding: .utf8) {
                     print("Received raw JSON response: \(jsonString)")
                 } else {
                     print("Received non-UTF8 data from API.")
                 }
            })
            .tryMap { data -> GeminiResponse in
                 do {
                     return try JSONDecoder().decode(GeminiResponse.self, from: data)
                 } catch {
                     if let apiError = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data) {
                         throw GeminiAPIError.apiError(apiError)
                     }
                     print("Decoding error: \(error)") // Log the actual decoding error
                     // Provide more context on decoding errors
                     if let jsonString = String(data: data, encoding: .utf8) {
                         print("Failed to decode JSON: \(jsonString)")
                     }
                     throw error // Rethrow original error
                 }
            }
            .receive(on: DispatchQueue.main)
            // Replace the loading indicator message
            // *** FIXED: Swapped order of receiveOutput and receiveCompletion ***
            .handleEvents(receiveOutput: { [weak self] _ in // <-- receiveOutput comes FIRST
                self?.removeLoadingIndicator()
            }, receiveCompletion: { [weak self] _ in       // <-- receiveCompletion comes SECOND
                self?.removeLoadingIndicator()
            })
            .sink(
                receiveCompletion: { [weak self] completion in
                    // Ensure loading indicator is removed even on failure (handled by handleEvents now, but keep for safety)
                    // self?.removeLoadingIndicator() // Already handled above
                    if case .failure(let error) = completion {
                        print("API Error Detailed: \(error)")
                        var errorMessage = "Sorry, an error occurred."
                        if let decodingError = error as? DecodingError {
                            // Extract more detail from decoding errors if possible
                            errorMessage = "Error processing response. Please try again."
                            print("Decoding Error Details: \(decodingError)")
                        } else if let apiError = error as? GeminiAPIError {
                            switch apiError {
                            case .apiError(let errorResponse):
                                 let detail = errorResponse.error.message ?? "Unknown API issue."
                                 errorMessage = "API Error (\(errorResponse.error.code ?? 0)): \(detail)"
                            }
                        } else {
                            // General network or other errors
                             // Check for common network errors
                             let nsError = error as NSError
                             if nsError.domain == NSURLErrorDomain {
                                 if nsError.code == NSURLErrorNotConnectedToInternet {
                                     errorMessage = "Network connection appears to be offline. Please check your connection."
                                 } else if nsError.code == NSURLErrorTimedOut {
                                     errorMessage = "The request timed out. Please try again."
                                 } else {
                                     errorMessage = "Network Error: \(error.localizedDescription)"
                                 }
                             } else {
                                 errorMessage = "API Error: \(error.localizedDescription)"
                             }
                        }
                         self?.addSystemMessage(errorMessage)
                    }
                },
                receiveValue: { [weak self] response in
                    // Safely unwrap the response structure
                    if let content = response.candidates?.first?.content?.parts?.first?.text, !content.isEmpty {
                        self?.addSystemMessage(content)
                     } else if let feedback = response.promptFeedback, feedback.blockReason != nil {
                         let reason = feedback.blockReason?.rawValue ?? "Unknown"
                         print("Prompt Feedback Received: BlockReason=\(reason)")
                         self?.addSystemMessage("Could not get recommendations. The request might have been blocked (Reason: \(reason)). Please try different phrasing.")
                     } else {
                        print("API returned no usable content or candidates.")
                        // Check finish reason if available
                        let finishReason = response.candidates?.first?.finishReason ?? "N/A"
                        print("Finish Reason: \(finishReason)")
                        if finishReason == "MAX_TOKENS" {
                            self?.addSystemMessage("The response was too long and got cut off. I can try again with a shorter request if you'd like.")
                        } else if finishReason == "SAFETY" {
                            self?.addSystemMessage("Could not get recommendations due to safety filters. Please try different phrasing.")
                        } else {
                            self?.addSystemMessage("Sorry, I couldn't find recommendations matching your criteria, or the response was empty (Finish Reason: \(finishReason)).")
                        }
                    }
                }
            )
            .store(in: &cancellables)
    }

     // Helper to remove the "..." loading indicator message
     private func removeLoadingIndicator() {
         DispatchQueue.main.async {
             if self.messages.last?.content == "..." && self.messages.last?.isUser == false {
                 _ = self.messages.popLast()
             }
         }
     }
}


// Models for Gemini API response (Updated for potential errors and feedback)
struct GeminiResponse: Codable {
    let candidates: [Candidate]?
    let promptFeedback: PromptFeedback?
}

struct Candidate: Codable {
    let content: Content?
    let finishReason: String? // e.g., "STOP", "MAX_TOKENS", "SAFETY", "RECITATION"
    let index: Int?
    let safetyRatings: [SafetyRating]?
}

struct Content: Codable {
    let parts: [Part]?
    let role: String? // e.g., "model"
}

struct Part: Codable {
    let text: String?
}

// Structure for potential API error responses
struct GeminiErrorResponse: Codable {
    let error: GeminiErrorDetail
}

struct GeminiErrorDetail: Codable {
    let code: Int?
    let message: String?
    let status: String? // e.g., "INVALID_ARGUMENT", "PERMISSION_DENIED"
}

// Custom Error Enum
enum GeminiAPIError: Error {
    case apiError(GeminiErrorResponse)
}

// Structure for Prompt Feedback
struct PromptFeedback: Codable {
    let blockReason: BlockReason?
    let safetyRatings: [SafetyRating]?

    enum BlockReason: String, Codable {
        case unspecified = "BLOCK_REASON_UNSPECIFIED"
        case safety = "SAFETY"
        case other = "OTHER"
    }
}

struct SafetyRating: Codable {
    let category: HarmCategory?
    let probability: HarmProbability?

    // Using more specific harm category names as per recent API docs
    enum HarmCategory: String, Codable {
        case harassment = "HARM_CATEGORY_HARASSMENT"
        case hateSpeech = "HARM_CATEGORY_HATE_SPEECH"
        case sexuallyExplicit = "HARM_CATEGORY_SEXUALLY_EXPLICIT"
        case dangerousContent = "HARM_CATEGORY_DANGEROUS_CONTENT"
        case unspecified = "HARM_CATEGORY_UNSPECIFIED"
    }

    enum HarmProbability: String, Codable {
         case unspecified = "HARM_PROBABILITY_UNSPECIFIED"
         case negligible = "NEGLIGIBLE"
         case low = "LOW"
         case medium = "MEDIUM"
         case high = "HIGH"
     }
}

// Add a preview provider for easier development (Optional but recommended)
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
