import Foundation

/// A minimal lexical description of a language — enough for colouring, not for parsing.
struct LanguageSpec {
    var name: String
    var lineComments: [String] = []
    var blockCommentOpen: String?
    var blockCommentClose: String?
    var nestedBlockComments = false
    /// Single-line string delimiters.
    var stringDelimiters: [Character] = []
    /// Delimiters that may span lines (`"""`, `'''`, backtick templates).
    var multilineStringDelimiters: [String] = []
    var escapeCharacter: Character? = "\\"
    var keywords: Set<String> = []
    var types: Set<String> = []
    var constants: Set<String> = []
    /// Characters that introduce an annotation/attribute/directive token (`@`, `#`).
    var annotationPrefixes: Set<Character> = []
    /// Colour capitalised identifiers as types (nice for Swift/Java-family code).
    var capitalisedIdentifiersAreTypes = true
    var caseSensitive = true

    static let plain = LanguageSpec(name: "Text")
}

/// Extension/filename → LanguageSpec.
enum LanguageCatalog {

    static func spec(forPath path: String) -> LanguageSpec {
        let name = (path as NSString).lastPathComponent
        let lowerName = name.lowercased()
        let ext = (lowerName as NSString).pathExtension

        // Salesforce metadata files are `*.object-meta.xml` and friends.
        if lowerName.hasSuffix("-meta.xml") { return xml }

        switch lowerName {
        case "makefile", "dockerfile", "gemfile", "rakefile", "brewfile", "procfile":
            return shell
        case ".gitignore", ".gitattributes", ".editorconfig", ".env":
            return ini
        default:
            break
        }

        switch ext {
        case "swift": return swift
        case "c", "h", "m": return cLike
        case "cpp", "cxx", "cc", "hpp", "hh", "hxx", "mm": return cpp
        case "cs": return csharp
        case "java", "gradle", "groovy", "scala": return java
        case "kt", "kts": return kotlin
        case "cls", "trigger", "apex": return apex
        case "js", "jsx", "mjs", "cjs", "vue", "svelte": return javascript
        case "ts", "tsx", "mts", "cts": return typescript
        case "json", "jsonc", "json5": return json
        case "py", "pyi", "pyw": return python
        case "rb", "erb": return ruby
        case "go": return go
        case "rs": return rust
        case "php": return php
        case "sh", "bash", "zsh", "fish", "ksh", "command": return shell
        case "yml", "yaml": return yaml
        case "toml", "ini", "cfg", "conf", "properties": return ini
        case "xml", "html", "htm", "xhtml", "svg", "plist", "storyboard", "xib", "xsd", "xsl": return xml
        case "css", "scss", "sass", "less": return css
        case "sql", "soql": return sql
        case "md", "markdown", "mdx", "rst", "txt", "text": return .plain
        case "diff", "patch", "rej": return .plain
        default: return .plain
        }
    }

    // MARK: - Specs

    static let swift = LanguageSpec(
        name: "Swift",
        lineComments: ["//"],
        blockCommentOpen: "/*", blockCommentClose: "*/", nestedBlockComments: true,
        stringDelimiters: ["\""],
        multilineStringDelimiters: ["\"\"\""],
        keywords: [
            "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import",
            "init", "inout", "internal", "let", "open", "operator", "private", "precedencegroup",
            "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias", "var",
            "break", "case", "catch", "continue", "default", "defer", "do", "else", "fallthrough",
            "for", "guard", "if", "in", "repeat", "return", "throw", "switch", "where", "while",
            "Any", "as", "await", "borrowing", "consuming", "each", "false", "is", "nil", "package",
            "self", "Self", "super", "throws", "true", "try", "async", "some", "any", "actor",
            "nonisolated", "isolated", "lazy", "final", "override", "convenience", "required",
            "weak", "unowned", "indirect", "mutating", "nonmutating", "dynamic", "optional",
            "get", "set", "willSet", "didSet", "sending",
        ],
        types: ["Int", "String", "Double", "Float", "Bool", "Array", "Dictionary", "Set", "Optional",
                "Result", "Void", "Character", "Data", "URL", "Date", "UUID", "Error"],
        constants: ["true", "false", "nil"],
        annotationPrefixes: ["@", "#"]
    )

    static let cLike = LanguageSpec(
        name: "C",
        lineComments: ["//"],
        blockCommentOpen: "/*", blockCommentClose: "*/",
        stringDelimiters: ["\"", "'"],
        keywords: [
            "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else",
            "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register",
            "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch",
            "typedef", "union", "unsigned", "void", "volatile", "while", "_Bool",
            "id", "nil", "self", "super", "YES", "NO", "instancetype", "nullable", "nonnull",
        ],
        constants: ["NULL", "nil", "YES", "NO", "true", "false"],
        annotationPrefixes: ["#", "@"]
    )

    static let cpp: LanguageSpec = {
        var spec = cLike
        spec.name = "C++"
        spec.keywords.formUnion([
            "alignas", "alignof", "and", "bool", "catch", "class", "concept", "constexpr", "consteval",
            "const_cast", "decltype", "delete", "dynamic_cast", "explicit", "export", "false", "friend",
            "mutable", "namespace", "new", "noexcept", "nullptr", "operator", "or", "private",
            "protected", "public", "reinterpret_cast", "requires", "static_assert", "static_cast",
            "template", "this", "thread_local", "throw", "true", "try", "typeid", "typename", "using",
            "virtual", "co_await", "co_return", "co_yield",
        ])
        return spec
    }()

    static let java = LanguageSpec(
        name: "Java",
        lineComments: ["//"],
        blockCommentOpen: "/*", blockCommentClose: "*/",
        stringDelimiters: ["\"", "'"],
        multilineStringDelimiters: ["\"\"\""],
        keywords: [
            "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class",
            "const", "continue", "default", "do", "double", "else", "enum", "extends", "final",
            "finally", "float", "for", "goto", "if", "implements", "import", "instanceof", "int",
            "interface", "long", "native", "new", "package", "private", "protected", "public",
            "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this",
            "throw", "throws", "transient", "try", "void", "volatile", "while", "var", "record",
            "sealed", "permits", "yield",
        ],
        constants: ["true", "false", "null"],
        annotationPrefixes: ["@"]
    )

    static let kotlin: LanguageSpec = {
        var spec = java
        spec.name = "Kotlin"
        spec.keywords.formUnion([
            "fun", "val", "when", "object", "companion", "data", "suspend", "lateinit", "init",
            "internal", "open", "override", "sealed", "typealias", "in", "out", "is", "as", "by",
            "constructor", "operator", "inline", "reified", "crossinline", "noinline", "vararg",
        ])
        return spec
    }()

    static let apex: LanguageSpec = {
        var spec = java
        spec.name = "Apex"
        spec.caseSensitive = false
        spec.keywords.formUnion([
            "global", "with", "without", "sharing", "testmethod", "trigger", "before", "after",
            "insert", "update", "upsert", "delete", "undelete", "merge", "system", "database",
            "select", "from", "where", "limit", "order", "group", "having", "and", "or", "not",
            "like", "in", "null", "true", "false", "virtual", "webservice", "future", "istest",
        ])
        spec.types.formUnion(["Id", "SObject", "List", "Map", "Set", "Integer", "Decimal", "String",
                              "Boolean", "Date", "Datetime", "Blob", "Object", "Schema"])
        return spec
    }()

    static let csharp: LanguageSpec = {
        var spec = java
        spec.name = "C#"
        spec.keywords.formUnion([
            "async", "await", "base", "checked", "decimal", "delegate", "event", "explicit", "fixed",
            "foreach", "get", "implicit", "in", "is", "lock", "namespace", "object", "operator",
            "out", "override", "params", "readonly", "ref", "sbyte", "set", "sizeof", "stackalloc",
            "string", "struct", "typeof", "uint", "ulong", "unchecked", "unsafe", "ushort", "using",
            "value", "virtual", "where", "yield", "nameof", "partial", "sealed",
        ])
        spec.annotationPrefixes = ["#"]
        return spec
    }()

    static let javascript = LanguageSpec(
        name: "JavaScript",
        lineComments: ["//"],
        blockCommentOpen: "/*", blockCommentClose: "*/",
        stringDelimiters: ["\"", "'"],
        multilineStringDelimiters: ["`"],
        keywords: [
            "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
            "delete", "do", "else", "export", "extends", "finally", "for", "function", "if",
            "import", "in", "instanceof", "let", "new", "of", "return", "static", "super", "switch",
            "this", "throw", "try", "typeof", "var", "void", "while", "with", "yield", "async",
            "get", "set", "from", "as",
        ],
        types: ["Array", "Object", "String", "Number", "Boolean", "Promise", "Map", "Set", "Date",
                "JSON", "Math", "RegExp", "Error", "Symbol", "BigInt"],
        constants: ["true", "false", "null", "undefined", "NaN", "Infinity"]
    )

    static let typescript: LanguageSpec = {
        var spec = javascript
        spec.name = "TypeScript"
        spec.keywords.formUnion([
            "abstract", "any", "as", "asserts", "bigint", "boolean", "declare", "enum", "implements",
            "infer", "interface", "is", "keyof", "namespace", "never", "number", "object", "override",
            "private", "protected", "public", "readonly", "require", "satisfies", "string", "symbol",
            "type", "unique", "unknown", "using", "accessor",
        ])
        spec.annotationPrefixes = ["@"]
        return spec
    }()

    static let json = LanguageSpec(
        name: "JSON",
        lineComments: ["//"],
        blockCommentOpen: "/*", blockCommentClose: "*/",
        stringDelimiters: ["\""],
        constants: ["true", "false", "null"],
        capitalisedIdentifiersAreTypes: false
    )

    static let python = LanguageSpec(
        name: "Python",
        lineComments: ["#"],
        stringDelimiters: ["\"", "'"],
        multilineStringDelimiters: ["\"\"\"", "'''"],
        keywords: [
            "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
            "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in",
            "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while",
            "with", "yield", "match", "case", "self", "cls",
        ],
        types: ["int", "str", "float", "bool", "list", "dict", "set", "tuple", "bytes", "object"],
        constants: ["True", "False", "None"],
        annotationPrefixes: ["@"],
        capitalisedIdentifiersAreTypes: false
    )

    static let ruby = LanguageSpec(
        name: "Ruby",
        lineComments: ["#"],
        stringDelimiters: ["\"", "'"],
        keywords: [
            "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else",
            "elsif", "end", "ensure", "for", "if", "in", "module", "next", "not", "or", "redo",
            "rescue", "retry", "return", "self", "super", "then", "undef", "unless", "until",
            "when", "while", "yield", "require", "require_relative", "attr_accessor", "attr_reader",
        ],
        constants: ["true", "false", "nil"],
        annotationPrefixes: ["@"]
    )

    static let go = LanguageSpec(
        name: "Go",
        lineComments: ["//"],
        blockCommentOpen: "/*", blockCommentClose: "*/",
        stringDelimiters: ["\"", "'"],
        multilineStringDelimiters: ["`"],
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
            "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
            "return", "select", "struct", "switch", "type", "var",
        ],
        types: ["bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int",
                "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16",
                "uint32", "uint64", "uintptr", "any"],
        constants: ["true", "false", "nil", "iota"]
    )

    static let rust = LanguageSpec(
        name: "Rust",
        lineComments: ["//"],
        blockCommentOpen: "/*", blockCommentClose: "*/", nestedBlockComments: true,
        stringDelimiters: ["\"", "'"],
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
            "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut",
            "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "type",
            "unsafe", "use", "where", "while", "union",
        ],
        types: ["bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize", "str",
                "u8", "u16", "u32", "u64", "u128", "usize", "String", "Vec", "Option", "Result", "Box"],
        constants: ["true", "false", "None", "Some", "Ok", "Err"],
        annotationPrefixes: ["#"]
    )

    static let php = LanguageSpec(
        name: "PHP",
        lineComments: ["//", "#"],
        blockCommentOpen: "/*", blockCommentClose: "*/",
        stringDelimiters: ["\"", "'"],
        keywords: [
            "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class", "clone",
            "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "empty",
            "enddeclare", "endfor", "endforeach", "endif", "endswitch", "endwhile", "enum", "extends",
            "final", "finally", "fn", "for", "foreach", "function", "global", "goto", "if",
            "implements", "include", "include_once", "instanceof", "insteadof", "interface", "isset",
            "list", "match", "namespace", "new", "or", "print", "private", "protected", "public",
            "readonly", "require", "require_once", "return", "static", "switch", "throw", "trait",
            "try", "unset", "use", "var", "while", "xor", "yield",
        ],
        constants: ["true", "false", "null", "TRUE", "FALSE", "NULL"],
        annotationPrefixes: ["#"],
        caseSensitive: false
    )

    static let shell = LanguageSpec(
        name: "Shell",
        lineComments: ["#"],
        stringDelimiters: ["\"", "'"],
        keywords: [
            "if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do",
            "done", "in", "function", "select", "time", "coproc", "local", "export", "readonly",
            "declare", "unset", "return", "shift", "source", "alias", "set", "trap", "echo", "cd",
        ],
        capitalisedIdentifiersAreTypes: false
    )

    static let yaml = LanguageSpec(
        name: "YAML",
        lineComments: ["#"],
        stringDelimiters: ["\"", "'"],
        constants: ["true", "false", "null", "yes", "no", "on", "off", "~"],
        capitalisedIdentifiersAreTypes: false
    )

    static let ini = LanguageSpec(
        name: "Config",
        lineComments: ["#", ";"],
        stringDelimiters: ["\"", "'"],
        constants: ["true", "false"],
        capitalisedIdentifiersAreTypes: false
    )

    static let xml = LanguageSpec(
        name: "XML",
        blockCommentOpen: "<!--", blockCommentClose: "-->",
        stringDelimiters: ["\"", "'"],
        escapeCharacter: nil,
        capitalisedIdentifiersAreTypes: false
    )

    static let css = LanguageSpec(
        name: "CSS",
        lineComments: ["//"],
        blockCommentOpen: "/*", blockCommentClose: "*/",
        stringDelimiters: ["\"", "'"],
        keywords: ["import", "media", "supports", "keyframes", "include", "mixin", "extend",
                   "function", "return", "if", "else", "each", "use", "forward", "charset", "font-face"],
        annotationPrefixes: ["@"],
        capitalisedIdentifiersAreTypes: false
    )

    static let sql = LanguageSpec(
        name: "SQL",
        lineComments: ["--", "#"],
        blockCommentOpen: "/*", blockCommentClose: "*/",
        stringDelimiters: ["'", "\""],
        keywords: [
            "select", "from", "where", "and", "or", "not", "insert", "into", "values", "update",
            "set", "delete", "create", "alter", "drop", "table", "view", "index", "join", "left",
            "right", "inner", "outer", "full", "on", "as", "group", "by", "order", "having",
            "limit", "offset", "union", "all", "distinct", "case", "when", "then", "else", "end",
            "null", "is", "in", "like", "between", "exists", "count", "sum", "avg", "min", "max",
            "primary", "key", "foreign", "references", "default", "constraint", "unique", "with",
        ],
        constants: ["null", "true", "false"],
        capitalisedIdentifiersAreTypes: false,
        caseSensitive: false
    )
}
