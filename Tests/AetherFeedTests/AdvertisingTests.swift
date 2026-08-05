import Foundation
import FoundationModels
import GRDB
import Testing

@testable import AetherFeed

@Suite struct AdvertisingTests {
    private func makeRepository() throws -> (Repository, DatabasePool) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherfeed-ads-\(UUID().uuidString).sqlite").path
        let pool = try DatabasePool(path: path)
        try Migrations.migrator.migrate(pool)
        return (Repository(pool: pool), pool)
    }

    /// Inserts a feed with the given headlines and returns their article ids.
    private func seed(
        _ repository: Repository, _ pool: DatabasePool, titles: [String],
        categoryName: String? = nil
    ) async throws -> [Int64] {
        let items = titles.enumerated().map { index, title in
            ParsedItem(
                guid: "g\(index)-\(UUID().uuidString)", url: nil, title: title, author: nil,
                publishedAt: Date(), contentHTML: "<p>\(title)</p>")
        }
        let feedId = try await repository.insertFeed(
            url: "https://example.com/\(UUID().uuidString)",
            parsed: ParsedFeed(title: "Feed", description: nil, siteURL: nil, items: items),
            categoryId: nil, newCategoryName: categoryName, etag: nil, lastModified: nil)
        return try await pool.read { db in
            try Int64.fetchAll(
                db, sql: "SELECT id FROM article WHERE feedId = ? ORDER BY id",
                arguments: [feedId])
        }
    }

    @Test func migrationAddsTheColumnDefaultingToFalse() async throws {
        let (repository, pool) = try makeRepository()
        let ids = try await seed(repository, pool, titles: ["A"])

        let article = try await pool.read { db in try Article.fetchOne(db, key: ids[0]) }
        #expect(article?.isAdvertising == false)
    }

    @Test func advertorialIsFlaggedTaggedAndMarkedRead() async throws {
        let (repository, pool) = try makeRepository()
        let ids = try await seed(repository, pool, titles: ["Sponsored"])

        try await repository.applyLLMResult(
            articleId: ids[0], summary: nil, tags: [.advertising],
            isAdvertising: true, markRead: true)

        let article = try await pool.read { db in try Article.fetchOne(db, key: ids[0]) }
        #expect(article?.isAdvertising == true)
        #expect(article?.isRead == true)
        // The summary is dropped on purpose — nothing to show, nothing to index.
        #expect(article?.summary == nil)
        #expect(article?.llmStatus == .done)

        let tags = try await pool.read { db in try Tag.fetchAll(db) }
        #expect(tags.count == 1)
        #expect(tags.first?.name == "Werbung")
        #expect(tags.first?.nameEn == "Advertising")
    }

    @Test func advertorialStaysUnreadWhenTheSettingIsOff() async throws {
        let (repository, pool) = try makeRepository()
        let ids = try await seed(repository, pool, titles: ["Sponsored"])

        try await repository.applyLLMResult(
            articleId: ids[0], summary: nil, tags: [.advertising],
            isAdvertising: true, markRead: false)

        let article = try await pool.read { db in try Article.fetchOne(db, key: ids[0]) }
        #expect(article?.isAdvertising == true)
        #expect(article?.isRead == false)
    }

    @Test func digestSkipsAdvertorials() async throws {
        let (repository, pool) = try makeRepository()
        let ids = try await seed(
            repository, pool, titles: ["Real news", "Sponsored"], categoryName: "News")

        try await repository.applyLLMResult(
            articleId: ids[0], summary: "a real summary", tags: [])
        try await repository.applyLLMResult(
            articleId: ids[1], summary: nil, tags: [.advertising],
            isAdvertising: true, markRead: true)

        let groups = try await repository.digestInputsByCategory()
        let titles = groups.flatMap { $0.articles.map(\.title) }
        #expect(titles.contains("Real news"))
        #expect(!titles.contains("Sponsored"))
    }

    @Test func arrivingAdvertorialDoesNotMakeTheDigestStale() async throws {
        let (repository, pool) = try makeRepository()
        let ids = try await seed(repository, pool, titles: ["Sponsored"])
        try await repository.applyLLMResult(
            articleId: ids[0], summary: nil, tags: [.advertising],
            isAdvertising: true, markRead: true)

        // Digest generated after the article arrived.
        try await repository.saveDigest(
            DigestPayload(overview: "o", sections: []), articleCount: 0)
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE digest SET generatedAt = ?",
                arguments: [Date().addingTimeInterval(-60)])
        }

        #expect(try await repository.digestIsStale() == false)
    }

    // MARK: - Quote verification (deterministic, no model required)

    @Test func unquotedOrInventedMarkersAreNotTrusted() {
        let text = "Anzeige: Luftbefeuchter für 29,98 Euro. Jetzt zugreifen."
        // Quote present in the text → trusted.
        #expect(LLMPipeline.isVerifiedAdvertising(flag: true, marker: "Anzeige", in: text))
        // Models reflow whitespace and change case when quoting.
        #expect(
            LLMPipeline.isVerifiedAdvertising(
                flag: true, marker: "jetzt\n  ZUGREIFEN", in: text))
        // Invented quote → the flag is dropped.
        #expect(
            !LLMPipeline.isVerifiedAdvertising(
                flag: true, marker: "In Partnerschaft mit", in: text))
        // No quote at all, or too short to mean anything.
        #expect(!LLMPipeline.isVerifiedAdvertising(flag: true, marker: "", in: text))
        #expect(!LLMPipeline.isVerifiedAdvertising(flag: true, marker: nil, in: text))
        #expect(!LLMPipeline.isVerifiedAdvertising(flag: true, marker: "An", in: text))
        // A quote without the flag stays false.
        #expect(!LLMPipeline.isVerifiedAdvertising(flag: false, marker: "Anzeige", in: text))
        #expect(!LLMPipeline.isVerifiedAdvertising(flag: nil, marker: "Anzeige", in: text))
    }

    @Test func markersAreRecognizedInEveryUILanguage() {
        // One label and one call to buy per language, quoted from the text.
        let markers = [
            "Anzeige: Testbericht", "Jetzt zugreifen und sparen",
            "Sponsored: our partner", "Buy now and save",
            "Publicité — notre partenaire", "Achetez maintenant sur la boutique",
            "Pubblicità: il nostro partner", "Acquista ora sullo shop",
            "Publicidad: nuestro socio", "Compra ahora en la tienda",
        ]
        for marker in markers {
            #expect(
                LLMPipeline.isVerifiedAdvertising(
                    flag: true, marker: marker, in: "Titel. \(marker). Rest des Texts."),
                "not recognized: \(marker)")
        }
    }

    @Test func accentsAndOrdinaryProseDoNotDecideTheOutcome() {
        // The model may drop accents when quoting — the match must survive.
        #expect(
            LLMPipeline.isVerifiedAdvertising(
                flag: true, marker: "Publicite", in: "Publicité : notre partenaire vous offre"))
        // Ordinary sentences in each language are not markers, even though
        // they talk about commerce.
        let innocuous = [
            "In diesen Vierteln sollten Interessenten zugreifen",
            "The company reported a drop in sales",
            "Le gouvernement annonce une baisse des prix",
            "L'azienda ha ridotto i prezzi dei suoi prodotti",
            "La empresa redujo los precios de sus productos",
        ]
        for sentence in innocuous {
            #expect(
                !LLMPipeline.isVerifiedAdvertising(
                    flag: true, marker: sentence, in: "Titel. \(sentence). Rest."),
                "wrongly treated as a marker: \(sentence)")
        }
    }

    @available(macOS 26.0, *)
    private func classify(_ user: String) async throws -> Bool {
        let client = AppleIntelligenceClient()
        let analysis: ArticleAnalysis = try await client.structured(
            system: LLMPipeline.analysisPrompt(), user: user, schema: ArticleAnalysis.schema)
        return LLMPipeline.isVerifiedAdvertising(
            flag: analysis.isAdvertising, marker: analysis.adMarker, in: user)
    }

    // MARK: - Live classification (skips itself when the model is unavailable)

    /// Runs the real production prompt plus the quote check against the
    /// on-device model. The negative cases are the ones that matter: a wrong
    /// `true` strips a real article of its summary and marks it read. All
    /// four came from actual runs against live feeds, where earlier prompt
    /// wordings flagged them as advertising.
    @Test @available(macOS 26.0, *) func classifiesAgainstLiveModel() async throws {
        let model = SystemLanguageModel(
            useCase: .general, guardrails: .permissiveContentTransformations)
        guard model.isAvailable else { return }

        let advertorial = try await classify(
            """
            Title: Anzeige: Luftbefeuchter von Levoit für 29,98 Euro bei Amazon

            Article:
            Bei Amazon ist der Luftbefeuchter von Levoit derzeit für 29,98 Euro \
            statt 49,99 Euro zu haben. Das Angebot gilt nur für kurze Zeit. \
            Jetzt zugreifen — über unseren Link bestellen und sparen.
            """)
        #expect(advertorial)

        // Business reporting about a company and its market.
        let businessNews = try await classify(
            """
            Title: Trotz Absturz am deutschen Heizungsmarkt: Italienischer Konzern \
            bereut Milliardenwette nicht

            Article:
            Die Ariston Group hat 2023 für rund eine Milliarde Euro das \
            Wärmepumpengeschäft von Bosch übernommen. Seitdem ist der deutsche \
            Heizungsmarkt eingebrochen. Der Konzernchef verteidigt die Übernahme \
            im Gespräch und verweist auf das Auslandsgeschäft.
            """)
        #expect(!businessNews)

        // Service piece with an interactive tool.
        let servicePiece = try await classify(
            """
            Title: Arbeitszeit: Dieser Rechner zeigt, wie viel Sie künftig arbeiten müssen

            Article:
            Die Koalition will die wöchentliche Höchstarbeitszeit flexibler \
            gestalten. Was das für einzelne Beschäftigte bedeutet, hängt von \
            Branche und Tarifvertrag ab. Ein Rechner zeigt die Auswirkungen für \
            verschiedene Modelle.
            """)
        #expect(!servicePiece)

        // A bare RSS teaser about a product, with a price remark but no ad
        // marker — the shape that fooled the model most easily.
        let productTeaser = try await classify(
            """
            Title: X-Files 21369: Legos Akte-X-Set bringt Figuren von Mulder, \
            Scully und Aliens

            Article:
            Die insgesamt acht Minifiguren aus der Serie machen den Lego-Bausatz \
            auch besonders teuer. (Lego, Spielzeug)
            """)
        #expect(!productTeaser)

        // "zugreifen" in its ordinary German sense, not as a call to buy.
        let propertyAdvice = try await classify(
            """
            Title: Trendviertel: Leipzig – In diesen Vierteln sollten Interessenten \
            zugreifen

            Article:
            Die Preise für Eigentumswohnungen in Leipzig steigen wieder. Makler \
            sehen vor allem im Leipziger Osten Nachholbedarf. In diesen Vierteln \
            sollten Interessenten zugreifen, bevor die Nachfrage weiter anzieht.
            """)
        #expect(!propertyAdvice)

        // Feeds are not German-only: the model must find and quote the
        // marker in the article's own language.
        let englishAd = try await classify(
            """
            Title: Sponsored: This robot vacuum is down to $199 at Amazon

            Article:
            Our partner Roborock is offering the Q7 Max at its lowest price yet. \
            Buy now through the link below — we earn a commission on purchases \
            made through our links.
            """)
        #expect(englishAd)

        let frenchNews = try await classify(
            """
            Title: Le gouvernement annonce une baisse des prix de l'électricité

            Article:
            Le ministre de l'Économie a présenté jeudi une réforme des tarifs \
            réglementés. La baisse atteindra en moyenne quatre pour cent l'an \
            prochain. Les associations de consommateurs restent prudentes.
            """)
        #expect(!frenchNews)

        // Ordinary news that happens to be about a commercial service.
        let plainNews = try await classify(
            """
            Title: In 24 Stunden: Neue Fährroute verbindet Italien mit Algerien

            Article:
            Eine neue Fährverbindung soll ab dem Frühjahr Rom mit Algier \
            verbinden. Die Überfahrt dauert rund 24 Stunden. Die Reederei will \
            damit auf die gestiegene Nachfrage im Mittelmeerraum reagieren.
            """)
        #expect(!plainNews)
    }
}
