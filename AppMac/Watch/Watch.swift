//
//  Watch.swift
//  Watch
//
//  Created by Рауан Аблайхан on 27.10.2026.
//

import AppIntents

struct Watch: AppIntent {
    static var title: LocalizedStringResource { "Watch" }
    
    func perform() async throws -> some IntentResult {
        return .result()
    }
}
