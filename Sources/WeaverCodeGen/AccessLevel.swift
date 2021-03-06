//
//  AccessLevel.swift
//  WeaverCodeGen
//
//  Created by Théophane Rupin on 5/7/18.
//

import Foundation

public enum AccessLevel: String {
    case `public` = "public"
    case `internal` = "internal"
    
    static let `default`: AccessLevel = .`internal`
}
