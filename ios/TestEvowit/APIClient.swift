import Foundation

struct APIClient {
    private struct DetectQuestionRequest: Encodable {
        let imageBase64: String
        let focusRect: ServerNormalizedRect?
    }

    func solve(_ request: SolveProblemRequest, imageData: Data) async throws -> SolveProblemResponse {
        let boundary = "Boundary-\(UUID().uuidString)"
        var urlRequest = URLRequest(url: AppConfig.backendBaseURL.appending(path: "api/solve/upload"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try makeMultipartBody(request: request, imageData: imageData, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "server error"
            throw NSError(
                domain: "APIClient",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        return try JSONDecoder().decode(SolveProblemResponse.self, from: data)
    }

    func detectQuestion(
        in imageData: Data,
        focusRect: ServerNormalizedRect? = nil
    ) async throws -> ServerQuestionDetectionResponse {
        var urlRequest = URLRequest(url: AppConfig.backendBaseURL.appending(path: "api/detect-question"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(
            DetectQuestionRequest(
                imageBase64: imageData.base64EncodedString(),
                focusRect: focusRect
            )
        )

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "server error"
            throw NSError(
                domain: "APIClient",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        return try JSONDecoder().decode(ServerQuestionDetectionResponse.self, from: data)
    }

    private func makeMultipartBody(
        request: SolveProblemRequest,
        imageData: Data,
        boundary: String
    ) throws -> Data {
        var body = Data()

        func appendField(_ name: String, value: String?) {
            guard let value, !value.isEmpty else { return }
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString(value)
            body.appendString("\r\n")
        }

        appendField("sessionId", value: request.sessionId)
        appendField("subject", value: request.subject)
        appendField("gradeBand", value: request.gradeBand)
        appendField("answerStyle", value: request.answerStyle)
        appendField("questionHint", value: request.questionHint)
        appendField("recognizedText", value: request.recognizedText)

        if let clientTrace = request.clientTrace {
            let traceData = try JSONEncoder().encode(clientTrace)
            appendField("clientTrace", value: String(decoding: traceData, as: UTF8.self))
        }

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"image\"; filename=\"problem.jpg\"\r\n")
        body.appendString("Content-Type: image/jpeg\r\n\r\n")
        body.append(imageData)
        body.appendString("\r\n")
        body.appendString("--\(boundary)--\r\n")
        return body
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
