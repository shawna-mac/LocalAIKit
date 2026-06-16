//
//  ChatMessage.swift
//  LocalAIAppKitDemo
//
//  Created by Shawna MacNabb on 6/16/26.
//

import Foundation

struct ChatMessage: Identifiable, Hashable {
    enum Role: String, Hashable {
        case system
        case user
        case assistant
        case error
    }

    let id = UUID()
    var role: Role
    var text: String
}
