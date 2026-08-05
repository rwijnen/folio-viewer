import Foundation

/// Greets people in a handful of languages.
struct Greeter {

    enum Language: String {
        case english
        case dutch
        case german
    }

    let language: Language

    init(language: Language = .english) {
        self.language = language
    }

    func greeting(for name: String) -> String {
        switch language {
        case .english:
            return "Hello, \(name)!"
        case .dutch:
            return "Hallo, \(name)!"
        case .german:
            return "Hallo, \(name)!"
        }
    }

    // A deliberately long block of unchanged code so the viewer has something
    // to collapse. None of the lines below are touched by the sample diff.
    func farewell(for name: String) -> String {
        switch language {
        case .english:
            return "Goodbye, \(name)."
        case .dutch:
            return "Tot ziens, \(name)."
        case .german:
            return "Auf Wiedersehen, \(name)."
        }
    }

    func smallTalk() -> [String] {
        [
            "Lovely weather today.",
            "Did you catch the game?",
            "This coffee is surprisingly good.",
        ]
    }

    func describe() -> String {
        "Greeter(language: \(language.rawValue))"
    }

    func validate(name: String) throws {
        guard !name.isEmpty else {
            throw GreeterError.emptyName
        }
    }
}

enum GreeterError: Error {
    case emptyName
}
