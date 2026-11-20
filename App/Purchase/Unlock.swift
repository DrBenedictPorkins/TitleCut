import Observation
import OSLog
import StoreKit

/// The one-time purchase that removes the export watermark (PLAN, paid unlock).
///
/// Unlocked means `Transaction.currentEntitlements` holds a verified,
/// unrevoked transaction for `productID`. Nothing is cached: exports ask
/// `refresh()` when they start.
@MainActor
@Observable
final class Unlock {
    static let shared = Unlock()
    static let productID = "com.byteclub.titlecut.unlock"
    /// Treats the app as unlocked without asking the App Store, so exports
    /// carry no watermark. Hard-coded on for now; set false to check the
    /// purchase again.
    static let alwaysUnlocked = true

    /// `nil` until the App Store answers, or if it has no such product.
    private(set) var product: Product?
    /// As of the last `refresh()`.
    private(set) var isUnlocked = false
    /// A purchase or restore is in progress.
    private(set) var isBusy = false

    @ObservationIgnored private var updates: Task<Void, Never>?
    private static let log = Logger(subsystem: "com.byteclub.titlecut", category: "Unlock")

    private init() {}

    /// Loads the product, reads the entitlement, and watches for purchases
    /// made elsewhere (another Mac, Ask to Buy, a refund).
    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                _ = await self?.refresh()
            }
        }
        Task {
            await loadProduct()
            _ = await refresh()
        }
    }

    /// Reads the entitlement now. Returns whether the app is unlocked.
    @discardableResult
    func refresh() async -> Bool {
        if Self.alwaysUnlocked {
            isUnlocked = true
            return true
        }
        var unlocked = false
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement,
               transaction.productID == Self.productID, transaction.revocationDate == nil {
                unlocked = true
            }
        }
        isUnlocked = unlocked
        return unlocked
    }

    /// Buys the unlock. Returns whether the app is now unlocked; `false`
    /// when the person cancelled or the purchase awaits approval.
    func purchase() async throws -> Bool {
        if product == nil { await loadProduct() }
        guard let product else { throw UnlockError.productUnavailable }
        isBusy = true
        defer { isBusy = false }
        switch try await product.purchase() {
        case .success(.verified(let transaction)):
            await transaction.finish()
            return await refresh()
        case .success(.unverified(_, let error)):
            throw error
        case .pending, .userCancelled:
            return false
        @unknown default:
            return false
        }
    }

    /// Restore Purchases: asks the App Store for this Apple Account's
    /// purchases, then reads the entitlement. Returns whether it is unlocked.
    func restore() async throws -> Bool {
        isBusy = true
        defer { isBusy = false }
        try await AppStore.sync()
        return await refresh()
    }

    private func loadProduct() async {
        do {
            product = try await Product.products(for: [Self.productID]).first
        } catch {
            Self.log.error("Loading the unlock product failed: \(error, privacy: .public)")
        }
    }

    enum UnlockError: LocalizedError {
        case productUnavailable

        var errorDescription: String? {
            "The App Store did not offer the unlock."
        }
    }
}
