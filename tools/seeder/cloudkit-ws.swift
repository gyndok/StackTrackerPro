import Foundation
import CryptoKit

// CloudKit Web Services Server-to-Server auth.
//
// Replaces the `xcrun cktool` user-token dance (short-lived, minted by hand
// every session) with a signed HTTPS request straight to CloudKit Web
// Services, using a long-lived Server-to-Server key. See "Composing Web
// Service Requests" in Apple's CloudKit Web Services Reference.
//
//   date   = ISO8601 string, generated once per request and reused verbatim
//            in both the signed message and the request header
//   body   = the exact bytes sent as the HTTP body
//   digest = SHA256(body), base64
//   message = "\(date):\(digest):\(subpath)"
//   signature = ECDSA P-256 signature over message's UTF-8 bytes, DER, base64
//
// Three headers carry the result:
//   X-Apple-CloudKit-Request-KeyID
//   X-Apple-CloudKit-Request-ISO8601Date
//   X-Apple-CloudKit-Request-SignatureV1

struct S2SKey {
    let keyID: String
    let privateKey: P256.Signing.PrivateKey
}

/// Loads the Server-to-Server key from ~/.config/stacktrackerpro-seeder/.
/// Never call this from a dry-run path — only when a request is actually
/// about to be signed (`--execute`, `auth-check`), so plain dry runs and
/// tests work on a machine with no key configured.
func loadS2SKey() throws -> S2SKey {
    let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/stacktrackerpro-seeder")
    let keyIDPath = configDir.appendingPathComponent("keyid")
    let pemPath = configDir.appendingPathComponent("eckey.pem")

    let setupInstructions = """
    No CloudKit Server-to-Server key found at \(configDir.path)

    One-time setup:
      1. CloudKit Console (https://icloud.developer.apple.com) → your container
         (\(containerID)) → Server-to-Server Keys → Add a Key.
      2. Download the generated private key PEM and save it to:
           \(pemPath.path)
         (Apple's downloaded PEM is already in the right format for this tool —
         no `openssl ec` conversion needed.)
      3. Lock it down:
           chmod 600 \(pemPath.path)
      4. Copy the key's hex Key ID (shown next to the key in the Console) into:
           \(keyIDPath.path)
      5. Verify with:
           seeder auth-check --env development
    """

    guard let rawKeyID = try? String(contentsOf: keyIDPath, encoding: .utf8) else {
        throw Err(setupInstructions)
    }
    let keyID = rawKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !keyID.isEmpty else { throw Err(setupInstructions) }

    guard let pem = try? String(contentsOf: pemPath, encoding: .utf8) else {
        throw Err(setupInstructions)
    }

    do {
        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: pem)
        return S2SKey(keyID: keyID, privateKey: privateKey)
    } catch {
        throw Err("Could not parse EC private key at \(pemPath.path): \(error)\n\n\(setupInstructions)")
    }
}

func wsSubpath(env: String, operation: String) -> String {
    "/database/1/\(containerID)/\(env)/public/records/\(operation)"
}

func signedRequest(subpath: String, body: Data, key: S2SKey) throws -> URLRequest {
    let dateString = ISO8601DateFormatter().string(from: Date())
    let bodyHash = Data(SHA256.hash(data: body)).base64EncodedString()
    let message = "\(dateString):\(bodyHash):\(subpath)"
    let signature = try key.privateKey.signature(for: Data(message.utf8))

    guard let url = URL(string: "https://api.apple-cloudkit.com" + subpath) else {
        throw Err("invalid CloudKit Web Services URL for subpath \(subpath)")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
    request.setValue(key.keyID, forHTTPHeaderField: "X-Apple-CloudKit-Request-KeyID")
    request.setValue(dateString, forHTTPHeaderField: "X-Apple-CloudKit-Request-ISO8601Date")
    request.setValue(signature.derRepresentation.base64EncodedString(), forHTTPHeaderField: "X-Apple-CloudKit-Request-SignatureV1")
    return request
}

/// Converts the cktool-shaped `{"type": "stringType", "value": …}` fields
/// dict (what `runPublish` already builds) into the Web Services shape,
/// `{"value": …}` with no type key — the WS API infers types, except
/// timestamps (which it wants as milliseconds since epoch, not ISO strings).
func toWSFields(_ fields: [String: Any]) throws -> [String: Any] {
    let iso = ISO8601DateFormatter()
    var out: [String: Any] = [:]
    for (name, raw) in fields {
        guard let entry = raw as? [String: Any], let type = entry["type"] as? String, let value = entry["value"] else {
            throw Err("toWSFields: field '\(name)' is missing type/value")
        }
        switch type {
        case "stringType", "int64Type", "doubleType":
            out[name] = ["value": value]
        case "timestampType":
            guard let string = value as? String, let date = iso.date(from: string) else {
                throw Err("toWSFields: field '\(name)' timestamp value is not a parseable ISO8601 string: \(value)")
            }
            out[name] = ["value": Int(date.timeIntervalSince1970 * 1000)]
        default:
            throw Err("toWSFields: field '\(name)' has unsupported type '\(type)'")
        }
    }
    return out
}

/// Shared POST-and-parse for both records/modify and records/query: sends
/// the signed request, surfaces HTTP and CloudKit-level errors loudly, and
/// hands back the parsed top-level JSON object on success.
private func wsPost(subpath: String, body: [String: Any], key: S2SKey) async throws -> [String: Any] {
    let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    let request = try signedRequest(subpath: subpath, body: bodyData, key: key)
    let (data, response) = try await URLSession.shared.data(for: request)

    guard let http = response as? HTTPURLResponse else {
        throw Err("CloudKit Web Services request produced no HTTP response")
    }
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

    guard http.statusCode == 200 else {
        let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<\(data.count) bytes, undecodable>"
        throw Err("CloudKit Web Services HTTP \(http.statusCode): \(preview)")
    }
    if let errorCode = json?["serverErrorCode"] as? String {
        let reason = json?["reason"] as? String ?? "unknown reason"
        throw Err("CloudKit Web Services error \(errorCode): \(reason)")
    }
    return json ?? [:]
}

func wsModifyRecords(env: String, recordType: String, fields: [String: Any], key: S2SKey) async throws {
    let wsFields = try toWSFields(fields)
    let body: [String: Any] = [
        "operations": [
            [
                "operationType": "create",
                "record": [
                    "recordType": recordType,
                    "fields": wsFields
                ] as [String: Any]
            ]
        ]
    ]
    let json = try await wsPost(subpath: wsSubpath(env: env, operation: "modify"), body: body, key: key)
    if let records = json["records"] as? [[String: Any]] {
        for record in records {
            if let errorCode = record["serverErrorCode"] as? String {
                let reason = record["reason"] as? String ?? "unknown reason"
                throw Err("CloudKit Web Services record error \(errorCode): \(reason)")
            }
        }
    }
}

private func wsQueryRecords(env: String, body: [String: Any], key: S2SKey) async throws -> [[String: Any]] {
    let json = try await wsPost(subpath: wsSubpath(env: env, operation: "query"), body: body, key: key)
    return (json["records"] as? [[String: Any]]) ?? []
}

/// True when a `SharedTournament` with this exact `deduplicationKey` is
/// already visible in `env`. Tries a server-side filtered query first; if
/// the field isn't indexed as queryable, falls back to an unfiltered scan
/// (resultsLimit 200) with a client-side match and prints a one-line notice
/// suggesting the Console index, so callers aren't silently stuck.
func wsQueryByDedupKey(env: String, dedupKey: String, key: S2SKey) async throws -> Bool {
    let filteredBody: [String: Any] = [
        "query": [
            "recordType": recordType,
            "filterBy": [
                [
                    "fieldName": "deduplicationKey",
                    "comparator": "EQUALS",
                    "fieldValue": ["value": dedupKey]
                ]
            ]
        ] as [String: Any],
        "resultsLimit": 1
    ]
    do {
        let records = try await wsQueryRecords(env: env, body: filteredBody, key: key)
        return !records.isEmpty
    } catch let err as Err where err.description.contains("BAD_REQUEST") || err.description.lowercased().contains("not queryable") {
        print("NOTICE: 'deduplicationKey' isn't indexed as queryable in \(env) — falling back to an unfiltered scan. Add a QUERYABLE index for deduplicationKey in CloudKit Console for faster --skip-existing checks.")
        let fallbackBody: [String: Any] = [
            "query": ["recordType": recordType] as [String: Any],
            "resultsLimit": 200
        ]
        let records = try await wsQueryRecords(env: env, body: fallbackBody, key: key)
        return records.contains { record in
            guard let fields = record["fields"] as? [String: Any],
                  let field = fields["deduplicationKey"] as? [String: Any],
                  let value = field["value"] as? String else { return false }
            return value == dedupKey
        }
    }
}

func runAuthCheck(environment: String) async throws {
    let key = try loadS2SKey()
    let body: [String: Any] = [
        "query": ["recordType": recordType] as [String: Any],
        "resultsLimit": 1
    ]
    let records = try await wsQueryRecords(env: environment, body: body, key: key)
    print("AUTH OK (\(environment), \(records.count) record(s) visible)")
}
