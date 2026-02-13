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
        
        let urlString = "\(baseURL)/\(modelName):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            completion(.failure(.invalidURL))
            return
        }
        
        // Resize image to reduce payload size and latency (max 1024px is usually plenty for description)
        let resizedImage = resizeImage(image: image, targetSize: CGSize(width: 1024, height: 1024))
        
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
            completion(.failure(.imageConversionFailed)) // Generic error for JSON fail
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
            
            // Debug print
            // if let jsonStr = String(data: data, encoding: .utf8) { print("Gemini Response: \(jsonStr)") }
            
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
    
    private func resizeImage(image: UIImage, targetSize: CGSize) -> UIImage {
        let size = image.size
        
        let widthRatio  = targetSize.width  / size.width
        let heightRatio = targetSize.height / size.height
        
        // Figure out what our orientation is, and use that to form the rectangle
        var newSize: CGSize
        if(widthRatio > heightRatio) {
            newSize = CGSize(width: size.width * heightRatio, height: size.height * heightRatio)
        } else {
            newSize = CGSize(width: size.width * widthRatio,  height: size.height * widthRatio)
        }
        
        // This is the rect that we've calculated out and this is what is actually used below
        let rect = CGRect(x: 0, y: 0, width: newSize.width, height: newSize.height)
        
        // Actually do the resizing to the rect using the ImageContext stuff
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: rect)
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return newImage ?? image
    }
}
