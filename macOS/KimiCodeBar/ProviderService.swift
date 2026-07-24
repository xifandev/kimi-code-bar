import Foundation

// MARK: - 平台类型

enum ProviderType: String, CaseIterable, Identifiable {
    case kimi
    case deepseek

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kimi: return "Kimi"
        case .deepseek: return "DeepSeek"
        }
    }

    /// 菜单栏缩写
    var menuBarAbbreviation: String {
        switch self {
        case .kimi: return "Kimi"
        case .deepseek: return "DS"
        }
    }

    /// API Key 前缀提示（用于格式校验）
    var apiKeyPrefix: String {
        switch self {
        case .kimi: return "sk-kimi-"
        case .deepseek: return "sk-"
        }
    }

    var baseURL: String {
        switch self {
        case .kimi: return "https://api.kimi.com"
        case .deepseek: return "https://api.deepseek.com"
        }
    }

    var consoleURL: URL? {
        switch self {
        case .kimi: return URL(string: "https://www.kimi.com/code/console")
        case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")
        }
    }
}

// MARK: - 平台余额

struct ProviderBalance: Equatable {
    let provider: ProviderType
    let totalBalance: Double
    let currency: String
    let grantedBalance: Double
    let toppedUpBalance: Double
    let isAvailable: Bool
}

// MARK: - 平台状态

struct ProviderState {
    var balance: ProviderBalance?
    var isLoading = false
    var errorMessage: String?
}

// MARK: - 平台错误

enum ProviderError: Error {
    case invalidKeyFormat
    case networkError(String)
    case httpError(statusCode: Int, message: String)
    case badResponse
    case badURL
}

// MARK: - 平台服务协议

protocol ProviderServiceProtocol {
    var provider: ProviderType { get }
    func fetchBalance(apiKey: String) async -> Result<ProviderBalance, ProviderError>
}

// MARK: - DeepSeek 服务

/// GET https://api.deepseek.com/user/balance
/// Authorization: Bearer {apiKey}
final class DeepSeekService: ProviderServiceProtocol {
    let provider: ProviderType = .deepseek

    func fetchBalance(apiKey: String) async -> Result<ProviderBalance, ProviderError> {
        guard let url = URL(string: "https://api.deepseek.com/user/balance") else {
            return .failure(.badResponse)
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.badResponse)
            }

            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                if httpResponse.statusCode == 401 {
                    return .failure(.invalidKeyFormat)
                }
                return .failure(.httpError(statusCode: httpResponse.statusCode, message: body))
            }

            struct BalanceInfo: Codable {
                let currency: String
                let totalBalance: String
                let grantedBalance: String
                let toppedUpBalance: String

                enum CodingKeys: String, CodingKey {
                    case currency
                    case totalBalance = "total_balance"
                    case grantedBalance = "granted_balance"
                    case toppedUpBalance = "topped_up_balance"
                }
            }

            struct BalanceResponse: Codable {
                let isAvailable: Bool
                let balanceInfos: [BalanceInfo]

                enum CodingKeys: String, CodingKey {
                    case isAvailable = "is_available"
                    case balanceInfos = "balance_infos"
                }
            }

            let balanceResponse = try JSONDecoder().decode(BalanceResponse.self, from: data)
            let primary = balanceResponse.balanceInfos.first

            return .success(ProviderBalance(
                provider: .deepseek,
                totalBalance: primary.flatMap { Double($0.totalBalance) } ?? 0,
                currency: primary?.currency ?? "CNY",
                grantedBalance: primary.flatMap { Double($0.grantedBalance) } ?? 0,
                toppedUpBalance: primary.flatMap { Double($0.toppedUpBalance) } ?? 0,
                isAvailable: balanceResponse.isAvailable
            ))
        } catch is DecodingError {
            return .failure(.badResponse)
        } catch {
            return .failure(.networkError(error.localizedDescription))
        }
    }
}

