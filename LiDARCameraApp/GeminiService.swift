//
//  GeminiService.swift
//  LiDARCameraApp
//
//  Created by Gemini CLI on 02/12/26.
//

import Foundation
import UIKit

enum GeminiError: Error {
    case invalidURL
    case noAPIKey
    case imageConversionFailed
    case networkError(Error)
    case invalidResponse
    case apiError(String)
}

class GeminiService {
    static let shared = GeminiService()
    
    // Using the latest Flash Lite model as requested
    private let modelName = "gemini-flash-lite-latest"
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"
    
    func generateContent(prompt: String, image: UIImage, completion: @escaping (Result<String, GeminiError>) -> Void) {
        let apiKey = AppConfig.geminiApiKey
        guard !apiKey.isEmpty, apiKey != "TODO_ADD_YOUR_API_KEY_HERE" else {
            completion(.failure(.noAPIKey))
            return
        }
        
        // Move to background thread to avoid lagging the UI during image processing and serialization
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let urlString = "\(self.baseURL)/\(self.modelName):generateContent?key=\(apiKey)"
            guard let url = URL(string: urlString) else {
                completion(.failure(.invalidURL))
                return
            }
            
            // Resize image to reduce payload size and latency
            let resizedImage = self.resizeImage(image: image, targetSize: CGSize(width: 1024, height: 1024))
            
            guard let imageData = resizedImage.jpegData(compressionQuality: 0.8) else {
                completion(.failure(.imageConversionFailed))
                return
            }
            
            let base64Image = imageData.base64EncodedString()
            
            // Construct JSON payload
            let parameters: [String: Any] = [
                "contents": [
                    [
                        "parts": [
                            ["text": prompt],
                            [
                                "inline_data": [
                                    "mime_type": "image/jpeg",
                                    "data": base64Image
                                ]
                            ]
                        ]
                    ]
                ],
                "generationConfig": [
                    "temperature": 0.4,
                    "maxOutputTokens": 100
                ]
            ]
            
            guard let httpBody = try? JSONSerialization.data(withJSONObject: parameters, options: []) else {
                completion(.failure(.imageConversionFailed))
                return
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = httpBody
            
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    completion(.failure(.networkError(error)))
                    return
                }
                
                guard let data = data else {
                    completion(.failure(.invalidResponse))
                    return
                }
                
                do {
                    if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                        if let candidates = json["candidates"] as? [[String: Any]],
                           let firstCandidate = candidates.first,
                           let content = firstCandidate["content"] as? [String: Any],
                           let parts = content["parts"] as? [[String: Any]],
                           let firstPart = parts.first,
                           let text = firstPart["text"] as? String {
                            completion(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                        } else if let errorDict = json["error"] as? [String: Any],
                                  let message = errorDict["message"] as? String {
                            completion(.failure(.apiError(message)))
                        } else {
                            completion(.failure(.invalidResponse))
                        }
                    } else {
                        completion(.failure(.invalidResponse))
                    }
                } catch {
                    completion(.failure(.invalidResponse))
                }
            }
            task.resume()
        }
    }
    
    private func resizeImage(image: UIImage, targetSize: CGSize) -> UIImage {
        let size = image.size

        let widthRatio  = targetSize.width  / size.width
        let heightRatio = targetSize.height / size.height

        var newSize: CGSize
        if widthRatio > heightRatio {
            newSize = CGSize(width: size.width * heightRatio, height: size.height * heightRatio)
        } else {
            newSize = CGSize(width: size.width * widthRatio,  height: size.height * widthRatio)
        }

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
