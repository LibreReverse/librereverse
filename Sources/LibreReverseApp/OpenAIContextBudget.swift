#if os(macOS)
import Foundation

extension LibreReverseOpenAIResponsesProvider: LibreReverseAskContextBudgetProvider {
    func contextBudget() async throws -> LibreReverseAskContextBudget {
        // No capacity discovery is available for arbitrary configured OpenAI
        // models here. Use a conservative envelope and reserve actual output.
        .init(contextTokens: 8_192, outputTokens: 4_096)
    }
}
#endif
