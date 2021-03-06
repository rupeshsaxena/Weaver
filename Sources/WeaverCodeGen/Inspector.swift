//
//  Inspector.swift
//  WeaverCodeGen
//
//  Created by Théophane Rupin on 3/7/18.
//

import Foundation
import WeaverDI

// MARK: - Inspector

public final class Inspector {

    private let graph = Graph()

    private lazy var resolutionCache = Set<ResolutionCacheIndex>()
    private lazy var buildCache = Set<BuildCacheIndex>()
    
    public init(syntaxTrees: [Expr]) throws {
        try buildGraph(from: syntaxTrees)
    }
    
    public func validate() throws {
        for dependency in graph.dependencies {
            try dependency.resolve(with: &resolutionCache)
            try dependency.build(with: &buildCache)
        }
    }
}

// MARK: - Graph Objects

private final class Graph {
    private var resolversByName = [String: Resolver]()
    private var resolversByType = [String: Resolver]()
    
    lazy var dependencies: [Dependency] = {
        var allDependencies = [Dependency]()
        allDependencies.append(contentsOf: resolversByName.values.flatMap { $0.dependencies.values })
        allDependencies.append(contentsOf: resolversByType.values.flatMap { $0.dependencies.values })

        var filteredDependencies = Set<Dependency>()
        return allDependencies.filter {
            if filteredDependencies.contains($0) {
                return false
            }
            filteredDependencies.insert($0)
            return true
        }
    }()
}

private final class Resolver {
    let typeName: String?
    var config: Set<ConfigurationAttribute> = Set()
    var dependencies: [DependencyIndex: Dependency] = [:]
    var dependents: [Resolver] = []

    var fileLocation: FileLocation

    init(typeName: String? = nil,
         file: String? = nil,
         line: Int? = nil) {
        self.typeName = typeName
        
        fileLocation = FileLocation(line: line, file: file)
    }
}

private struct DependencyIndex {
    let typeName: String?
    let name: String
}

private final class Dependency {
    let name: String
    let scope: Scope?
    let isCustom: Bool
    let associatedResolver: Resolver
    let dependentResovler: Resolver

    let fileLocation: FileLocation

    init(name: String,
         scope: Scope? = nil,
         isCustom: Bool,
         line: Int,
         file: String,
         associatedResolver: Resolver,
         dependentResovler: Resolver) {
        self.name = name
        self.scope = scope
        self.isCustom = isCustom
        self.associatedResolver = associatedResolver
        self.dependentResovler = dependentResovler

        fileLocation = FileLocation(line: line, file: file)
}
}

private struct ResolutionCacheIndex {
    let resolver: Resolver
    let dependencyIndex: DependencyIndex
}

private struct BuildCacheIndex {
    let resolver: Resolver
    let scope: Scope?
}

// MARK: - Graph

extension Graph {
    
    func insertResolver(with registerAnnotation: TokenBox<RegisterAnnotation>, fileName: String?) {
        let resolver = Resolver(typeName: registerAnnotation.value.typeName,
                                file: fileName,
                                line: registerAnnotation.line)
        resolversByName[registerAnnotation.value.name] = resolver
        resolversByType[registerAnnotation.value.typeName] = resolver
    }
    
    func insertResolver(with referenceAnnotation: ReferenceAnnotation) {
        if resolversByName[referenceAnnotation.name] != nil {
            return
        }
        resolversByName[referenceAnnotation.name] = Resolver()
    }

    func resolver(named name: String) -> Resolver? {
        return resolversByName[name]
    }
    
    func resolver(typed type: String, line: Int, fileName: String) -> Resolver {
        if let resolver = resolversByType[type] {
            resolver.fileLocation = FileLocation(line: line, file: fileName)
            return resolver
        }
        let resolver = Resolver(typeName: type, file: fileName, line: line)
        resolversByType[type] = resolver
        return resolver
    }
}

// MARK: - Builders

private extension Inspector {
    
    func buildGraph(from syntaxTrees: [Expr]) throws {
        collectResolvers(from: syntaxTrees)
        try linkResolvers(from: syntaxTrees)
    }

    private func collectResolvers(from syntaxTrees: [Expr]) {

        var fileName: String?
        
        // Insert the resolvers for which we know the type.
        for expr in ExprSequence(exprs: syntaxTrees) {
            switch expr {
            case .registerAnnotation(let token):
                graph.insertResolver(with: token, fileName: fileName)
                
            case .file(_, let _fileName):
                fileName = _fileName
            
            case .typeDeclaration,
                 .scopeAnnotation,
                 .referenceAnnotation,
                 .customRefAnnotation,
                 .parameterAnnotation:
                break
            }
        }

        // Insert the resolvers for which we don't know the type.
        for expr in ExprSequence(exprs: syntaxTrees) {
            switch expr {
            case .referenceAnnotation(let token):
                graph.insertResolver(with: token.value)
                
            case .file,
                 .registerAnnotation,
                 .typeDeclaration,
                 .scopeAnnotation,
                 .customRefAnnotation,
                 .parameterAnnotation:
                break
            }
        }
    }
    
    private func linkResolvers(from syntaxTrees: [Expr]) throws {
        
        for ast in syntaxTrees {
            switch ast {
            case .file(let types, let name):
                try linkResolvers(from: types, fileName: name)
                
            case .typeDeclaration,
                 .scopeAnnotation,
                 .registerAnnotation,
                 .referenceAnnotation,
                 .customRefAnnotation,
                 .parameterAnnotation:
                throw InspectorError.invalidAST(.unknown, unexpectedExpr: ast)
            }
        }
    }
    
    private func linkResolvers(from exprs: [Expr], fileName: String) throws {
        
        for expr in exprs {
            switch expr {
            case .typeDeclaration(let injectableType, let config, let children):
                let resolver = graph.resolver(typed: injectableType.value.name,
                                              line: injectableType.line,
                                              fileName: fileName)

                try resolver.update(with: children,
                                    config: config,
                                    fileName: fileName,
                                    graph: graph)
                
            case .file,
                 .scopeAnnotation,
                 .registerAnnotation,
                 .referenceAnnotation,
                 .customRefAnnotation,
                 .parameterAnnotation:
                throw InspectorError.invalidAST(.file(fileName), unexpectedExpr: expr)
            }
        }
    }
}

private extension Dependency {
    
    convenience init(dependentResolver: Resolver,
                     registerAnnotation: TokenBox<RegisterAnnotation>,
                     scopeAnnotation: ScopeAnnotation? = nil,
                     customRefAnnotation: CustomRefAnnotation?,
                     fileName: String,
                     graph: Graph) throws {

        guard let associatedResolver = graph.resolver(named: registerAnnotation.value.name) else {
            throw InspectorError.invalidGraph(registerAnnotation.printableDependency(file: fileName),
                                              underlyingError: .unresolvableDependency(history: []))
        }
        
        self.init(name: registerAnnotation.value.name,
                  scope: scopeAnnotation?.scope ?? .`default`,
                  isCustom: customRefAnnotation?.value ?? CustomRefAnnotation.defaultValue,
                  line: registerAnnotation.line,
                  file: fileName,
                  associatedResolver: associatedResolver,
                  dependentResovler: dependentResolver)
    }
    
    convenience init(dependentResolver: Resolver,
                     referenceAnnotation: TokenBox<ReferenceAnnotation>,
                     customRefAnnotation: CustomRefAnnotation?,
                     fileName: String,
                     graph: Graph) throws {

        guard let associatedResolver = graph.resolver(named: referenceAnnotation.value.name) else {
            throw InspectorError.invalidGraph(referenceAnnotation.printableDependency(file: fileName),
                                              underlyingError: .unresolvableDependency(history: []))
        }
        
        self.init(name: referenceAnnotation.value.name,
                  isCustom: customRefAnnotation?.value ?? CustomRefAnnotation.defaultValue,
                  line: referenceAnnotation.line,
                  file: fileName,
                  associatedResolver: associatedResolver,
                  dependentResovler: dependentResolver)
    }
}

private extension Resolver {
    
    func update(with children: [Expr],
                config: [TokenBox<ConfigurationAnnotation>],
                fileName: String,
                graph: Graph) throws {

        self.config = Set(config.map { $0.value.attribute })
        
        var registerAnnotations: [TokenBox<RegisterAnnotation>] = []
        var referenceAnnotations: [TokenBox<ReferenceAnnotation>] = []
        var scopeAnnotations: [String: ScopeAnnotation] = [:]
        var customRefAnnotations: [String: CustomRefAnnotation] = [:]
        
        for child in children {
            switch child {
            case .typeDeclaration(let injectableType, let config, let children):
                let resolver = graph.resolver(typed: injectableType.value.name,
                                              line: injectableType.line,
                                              fileName: fileName)

                try resolver.update(with: children,
                                    config: config,
                                    fileName: fileName,
                                    graph: graph)
                
            case .registerAnnotation(let registerAnnotation):
                registerAnnotations.append(registerAnnotation)
                
            case .referenceAnnotation(let referenceAnnotation):
                referenceAnnotations.append(referenceAnnotation)

            case .scopeAnnotation(let scopeAnnotation):
                scopeAnnotations[scopeAnnotation.value.name] = scopeAnnotation.value
                
            case .customRefAnnotation(let customRefAnnotation):
                customRefAnnotations[customRefAnnotation.value.name] = customRefAnnotation.value
                
            case .file,
                 .parameterAnnotation:
                break
            }
        }
        
        for registerAnnotation in registerAnnotations {
            let dependency = try Dependency(dependentResolver: self,
                                            registerAnnotation: registerAnnotation,
                                            scopeAnnotation: scopeAnnotations[registerAnnotation.value.name],
                                            customRefAnnotation: customRefAnnotations[registerAnnotation.value.name],
                                            fileName: fileName,
                                            graph: graph)
            let index = DependencyIndex(typeName: dependency.associatedResolver.typeName, name: dependency.name)
            dependencies[index] = dependency
            dependency.associatedResolver.dependents.append(self)
        }
        
        for referenceAnnotation in referenceAnnotations {
            let dependency = try Dependency(dependentResolver: self,
                                            referenceAnnotation: referenceAnnotation,
                                            customRefAnnotation: customRefAnnotations[referenceAnnotation.value.name],
                                            fileName: fileName,
                                            graph: graph)
            let index = DependencyIndex(typeName: dependency.associatedResolver.typeName, name: dependency.name)
            dependencies[index] = dependency
            dependency.associatedResolver.dependents.append(self)
        }
    }
}

// MARK: - Resolution Check

private extension Dependency {
    
    func resolve(with cache: inout Set<ResolutionCacheIndex>) throws {
        guard isReference && !isCustom else {
            return
        }

        do {

            if try dependentResovler.checkIsolation(history: []) == false {
                return
            }
            
            let index = DependencyIndex(typeName: associatedResolver.typeName, name: name)
            for dependent in dependentResovler.dependents {
                try dependent.resolveDependency(index: index, cache: &cache)
            }
            
        } catch let error as InspectorAnalysisError {
            throw InspectorError.invalidGraph(printableDependency, underlyingError: error)
        }
    }
}

private extension Resolver {
    
    func resolveDependency(index: DependencyIndex, cache: inout Set<ResolutionCacheIndex>) throws {
        let cacheIndex = ResolutionCacheIndex(resolver: self, dependencyIndex: index)
        guard !cache.contains(cacheIndex) else {
            return
        }

        var visitedResolvers = Set<Resolver>()
        var history = [InspectorAnalysisHistoryRecord]()
        try resolveDependency(index: index, visitedResolvers: &visitedResolvers, history: &history)
        
        cache.insert(cacheIndex)
    }
    
    private func resolveDependency(index: DependencyIndex, visitedResolvers: inout Set<Resolver>, history: inout [InspectorAnalysisHistoryRecord]) throws {
        if visitedResolvers.contains(self) {
            throw InspectorAnalysisError.cyclicDependency(history: history.cyclicDependencyDetection)
        }
        visitedResolvers.insert(self)

        history.append(.triedToResolveDependencyInType(printableDependency(name: index.name), stepCount: history.resolutionSteps.count))
        
        if let dependency = dependencies[index] {
            if let scope = dependency.scope, (dependency.isCustom && scope.allowsAccessFromChildren) || scope.allowsAccessFromChildren {
                return
            }
            history.append(.foundUnaccessibleDependency(dependency.printableDependency))
        } else {
            history.append(.dependencyNotFound(printableDependency(name: index.name)))
        }

        if try checkIsolation(history: history) == false {
           return
        }
        
        for dependent in dependents {
            var visitedResolversCopy = visitedResolvers
            if let _ = try? dependent.resolveDependency(index: index, visitedResolvers: &visitedResolversCopy, history: &history) {
                return
            }
        }
        
        throw InspectorAnalysisError.unresolvableDependency(history: history.unresolvableDependencyDetection)
    }
}

// MARK: - Isolation Check

private extension Resolver {
    
    func checkIsolation(history: [InspectorAnalysisHistoryRecord]) throws -> Bool {
        
        let connectedReferents = dependents.filter { !$0.config.isIsolated }
        
        switch (dependents.isEmpty, config.isIsolated) {
        case (true, false):
            throw InspectorAnalysisError.unresolvableDependency(history: history.unresolvableDependencyDetection)
            
        case (false, true) where !connectedReferents.isEmpty:
            throw InspectorAnalysisError.isolatedResolverCannotHaveReferents(typeName: typeName,
                                                                             referents: connectedReferents.map { $0.printableResolver })

        case (true, true):
            return false
            
        case (false, _):
            return true
        }
    }
}

// MARK: - Build Check

private extension Dependency {
    
    func build(with buildCache: inout Set<BuildCacheIndex>) throws {
        let buildCacheIndex = BuildCacheIndex(resolver: associatedResolver, scope: scope)
        guard !buildCache.contains(buildCacheIndex) else {
            return
        }
        buildCache.insert(buildCacheIndex)
        
        guard !isReference && !isCustom else {
            return
        }
        
        guard let scope = scope, !scope.allowsAccessFromChildren else {
            return
        }
        
        var visitedResolvers = Set<Resolver>()
        try associatedResolver.buildDependencies(from: self, visitedResolvers: &visitedResolvers, history: [])
    }
}

private extension Resolver {
    
    func buildDependencies(from sourceDependency: Dependency, visitedResolvers: inout Set<Resolver>, history: [InspectorAnalysisHistoryRecord]) throws {

        if visitedResolvers.contains(self) {
            throw InspectorError.invalidGraph(sourceDependency.printableDependency,
                                              underlyingError: .cyclicDependency(history: history.cyclicDependencyDetection))
        }
        visitedResolvers.insert(self)
        
        var history = history
        history.append(.triedToBuildType(printableResolver, stepCount: history.buildSteps.count))
        
        for dependency in dependencies.values {
            var visitedResolversCopy = visitedResolvers
            try dependency.associatedResolver.buildDependencies(from: sourceDependency,
                                                                visitedResolvers: &visitedResolversCopy,
                                                                history: history)
        }
    }
}

// MARK: - Utils

private extension Dependency {
    
    var isReference: Bool {
        return scope == nil
    }
}

// MARK: - Conversions

private extension TokenBox where T == RegisterAnnotation {
    
    func printableDependency(file: String) -> PrintableDependency {
        return PrintableDependency(fileLocation: FileLocation(line: line, file: file),
                                   name: value.name,
                                   typeName: value.typeName)
    }
}

private extension TokenBox where T == ReferenceAnnotation {
    
    func printableDependency(file: String) -> PrintableDependency {
        return PrintableDependency(fileLocation: FileLocation(line: line, file: file),
                                   name: value.name,
                                   typeName: value.typeName)
    }
}

private extension Dependency {
    
    var printableDependency: PrintableDependency {
        return PrintableDependency(fileLocation: fileLocation,
                                   name: name,
                                   typeName: associatedResolver.typeName)
    }
}

private extension Resolver {
    
    func printableDependency(name: String) -> PrintableDependency {
        return PrintableDependency(fileLocation: fileLocation, name: name, typeName: typeName)
    }
    
    var printableResolver: PrintableResolver {
        return PrintableResolver(fileLocation: fileLocation, typeName: typeName)
    }
}

// MARK: - Hashable

extension Resolver: Hashable {
    
    var hashValue: Int {
        return ObjectIdentifier(self).hashValue
    }
    
    static func ==(lhs: Resolver, rhs: Resolver) -> Bool {
        return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
}

extension Dependency: Hashable {

    var hashValue: Int {
        return ObjectIdentifier(self).hashValue
    }
    
    static func ==(lhs: Dependency, rhs: Dependency) -> Bool {
        return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
}

extension DependencyIndex: Hashable {
    
    var hashValue: Int {
        return (typeName ?? "").hashValue ^ name.hashValue
    }
    
    static func ==(lhs: DependencyIndex, rhs: DependencyIndex) -> Bool {
        guard lhs.name == rhs.name else { return false }
        guard lhs.typeName == rhs.typeName else { return false }
        return true
    }
}

extension ResolutionCacheIndex: Hashable {

    var hashValue: Int {
        return resolver.hashValue ^ dependencyIndex.hashValue
    }
    
    static func ==(lhs: ResolutionCacheIndex, rhs: ResolutionCacheIndex) -> Bool {
        guard lhs.resolver == rhs.resolver else { return false }
        guard lhs.dependencyIndex == rhs.dependencyIndex else { return false }
        return true
    }
}

extension BuildCacheIndex: Hashable {
    var hashValue: Int {
        return resolver.hashValue ^ (scope?.hashValue ?? 0)
    }
    
    static func ==(lhs: BuildCacheIndex, rhs: BuildCacheIndex) -> Bool {
        guard lhs.resolver == rhs.resolver else { return false }
        guard lhs.scope == rhs.scope else { return false }
        return true
    }
}

