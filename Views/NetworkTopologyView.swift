import SwiftUI

/// Bulletproof network topology visualization with real metrics.
/// Uses NetworkTopologyMonitor for actual ping data instead of fake hashes.
struct NetworkTopologyView: View {
    enum LinkType: String, Hashable {
        case wifi = "WiFi"
        case ethernet = "Ethernet"
        case thunderbolt = "Thunderbolt"
        case mixed = "Mixed"
        case unknown = "Unknown"

        var icon: String {
            switch self {
            case .wifi: return "wifi"
            case .ethernet: return "cable.connector"
            case .thunderbolt: return "bolt.horizontal.fill"
            case .mixed: return "arrow.left.arrow.right"
            case .unknown: return "network"
            }
        }
    }

    struct TopologyNode: Identifiable, Hashable {
        enum Kind: String, Hashable {
            case local = "Local"
            case paired = "Paired"
            case discovered = "Discovered"
        }

        let id: String
        let name: String
        let kind: Kind
        let linkType: LinkType
        let ipAddress: String
    }

    let nodes: [TopologyNode]
    @Binding var selectedNodeID: String?
    
    @State private var hoveredNodeID: String? = nil
    @State private var flowPhase: CGFloat = 0
    @State private var isAnimating: Bool = false
    @State private var lastNodesHash: Int = 0
    
    @StateObject private var monitor = NetworkTopologyMonitor.shared

    // MARK: - Body
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background
                backgroundLayer
                
                // Connection lines with traffic animation
                connectionsLayer(in: geo.size)
                
                // Node circles
                nodesLayer(in: geo.size)
                
                // Tooltip on hover
                tooltipLayer(in: geo.size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: nodes.map(\.id)) { oldValue, newValue in
                handleNodesChange(newValue)
            }
            .onAppear {
                startAnimation()
                refreshMetrics()
            }
            .onDisappear {
                stopAnimation()
            }
        }
    }

    // MARK: - Layers

    private var backgroundLayer: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.black.opacity(0.16), Color.black.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(OverlayTheme.border.opacity(0.28), lineWidth: 0.7)
            )
    }

    private func connectionsLayer(in size: CGSize) -> some View {
        ForEach(connections) { conn in
            ConnectionView(
                conn: conn,
                fromPoint: position(for: conn.a, in: size),
                toPoint: position(for: conn.b, in: size),
                flowPhase: flowPhase,
                remoteNode: nodes[safe: conn.b],
                metrics: metrics(for: nodes[safe: conn.b]?.id)
            )
        }
    }

    private func nodesLayer(in size: CGSize) -> some View {
        ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
            let pos = position(for: index, in: size)
            NodeCircle(
                name: node.name,
                kind: node.kind,
                isHovered: hoveredNodeID == node.id,
                isSelected: selectedNodeID == node.id,
                metrics: metrics(for: node.id),
                quality: connectionQuality(for: node.id)
            )
            .position(pos)
            .onHover { hovered in
                hoveredNodeID = hovered ? node.id : nil
            }
            .onTapGesture {
                selectedNodeID = node.id
            }
        }
    }

    private func tooltipLayer(in size: CGSize) -> some View {
        Group {
            if let hoveredNodeID,
               let hoveredIndex = nodes.firstIndex(where: { $0.id == hoveredNodeID }),
               let hoveredNode = nodes[safe: hoveredIndex] {
                let anchor = position(for: hoveredIndex, in: size)
                NodeTooltip(
                    name: hoveredNode.name,
                    kind: hoveredNode.kind,
                    ip: hoveredNode.ipAddress,
                    metrics: metrics(for: hoveredNode.id),
                    quality: connectionQuality(for: hoveredNode.id)
                )
                .position(x: min(max(anchor.x + 62, 90), size.width - 90),
                         y: min(max(anchor.y - 26, 34), size.height - 34))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    // MARK: - Metrics (Real Data)

    private func metrics(for nodeID: String?) -> NetworkTopologyMonitor.NodeMetrics? {
        guard let id = nodeID else { return nil }
        guard let node = nodes.first(where: { $0.id == id }) else { return nil }
        return monitor.metrics(for: id, name: node.name)
    }

    private func connectionQuality(for nodeID: String) -> NetworkTopologyMonitor.ConnectionQuality {
        monitor.connectionQuality(for: nodeID)
    }

    private func refreshMetrics() {
        for node in nodes {
            _ = monitor.metrics(for: node.id, name: node.name)
        }
    }

    // MARK: - Animation Management

    private func startAnimation() {
        guard !isAnimating else { return }
        isAnimating = true
        withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
            flowPhase = 1
        }
    }

    private func stopAnimation() {
        isAnimating = false
    }

    private func handleNodesChange(_ newNodeIDs: [String]) {
        let newHash = newNodeIDs.hashValue
        guard newHash != lastNodesHash else { return }
        lastNodesHash = newHash
        refreshMetrics()
    }

    // MARK: - Layout

    func position(for index: Int, in size: CGSize) -> CGPoint {
        let count = max(1, nodes.count)
        let center = CGPoint(x: size.width/2, y: size.height/2)
        if count == 1 { return center }
        if nodes[safe: index]?.kind == .local {
            return center
        }
        let localIndex = nodes.firstIndex(where: { $0.kind == .local }) ?? 0
        let peers = nodes.indices.filter { $0 != localIndex }
        guard let ringIndex = peers.firstIndex(of: index) else { return center }
        let ringCount = max(1, peers.count)

        // Stable positioning based on node ID hash (consistent across renders)
        let nodeHash = abs(nodes[index].id.hashValue)
        let baseAngle = CGFloat(ringIndex) / CGFloat(ringCount) * 2 * .pi - .pi / 2
        let angle = baseAngle + (CGFloat(nodeHash % 17) / 100.0) // Small jitter
        let baseRadius = min(size.width, size.height) * 0.34
        let radius = baseRadius * (0.88 + CGFloat((nodeHash % 9)) * 0.02)

        return CGPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius * 0.9
        )
    }

    var connections: [Connection] {
        guard nodes.count > 1 else { return [] }
        let localIndex = nodes.firstIndex(where: { $0.kind == .local }) ?? 0
        return nodes.indices.filter { $0 != localIndex }.map { Connection(a: localIndex, b: $0) }
    }

    struct Connection: Identifiable, Hashable {
        let a: Int
        let b: Int
        var id: String { "\(a)-\(b)" }
    }
}

// MARK: - Connection View

private struct ConnectionView: View {
    let conn: NetworkTopologyView.Connection
    let fromPoint: CGPoint
    let toPoint: CGPoint
    let flowPhase: CGFloat
    let remoteNode: NetworkTopologyView.TopologyNode?
    let metrics: NetworkTopologyMonitor.NodeMetrics?

    var body: some View {
        ZStack {
            // Base connection line
            connectionPath
                .stroke(OverlayTheme.textSecondary.opacity(0.28), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))

            // Traffic line with throughput-based color
            connectionPath
                .stroke(trafficColor.opacity(0.16), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

            // Traffic dots
            let seed = CGFloat(abs(conn.id.hashValue % 100)) / 100
            TrafficDot(color: trafficColor)
                .position(t1(from: fromPoint, to: toPoint, seed: seed))
            TrafficDot(color: trafficColor, opacity: 0.45, size: 3)
                .position(t2(from: fromPoint, to: toPoint, seed: seed))
            TrafficDot(color: trafficColor.opacity(0.8), opacity: 0.7, size: 3.5)
                .position(reverse1(from: fromPoint, to: toPoint, seed: seed))
            TrafficDot(color: trafficColor.opacity(0.7), opacity: 0.35, size: 2.8)
                .position(reverse2(from: fromPoint, to: toPoint, seed: seed))

            // Link badge
            if let remote = remoteNode {
                LinkBadge(
                    icon: remote.linkType.icon,
                    throughputMbps: metrics?.throughputMbps,
                    color: trafficColor
                )
                .position(midpoint(from: fromPoint, to: toPoint))
            }
        }
    }

    private var connectionPath: Path {
        var path = Path()
        path.move(to: fromPoint)
        path.addLine(to: toPoint)
        return path
    }

    private var trafficColor: Color {
        guard let metrics = metrics, metrics.isReachable else { return .gray }
        return linkColor(for: metrics.throughputMbps)
    }

    private func t1(from: CGPoint, to: CGPoint, seed: CGFloat) -> CGPoint {
        point(from: from, to: to, t: wrappedUnit(flowPhase + seed))
    }

    private func t2(from: CGPoint, to: CGPoint, seed: CGFloat) -> CGPoint {
        point(from: from, to: to, t: wrappedUnit(flowPhase + seed + 0.42))
    }

    private func reverse1(from: CGPoint, to: CGPoint, seed: CGFloat) -> CGPoint {
        point(from: to, to: from, t: wrappedUnit(flowPhase + seed + 0.2))
    }

    private func reverse2(from: CGPoint, to: CGPoint, seed: CGFloat) -> CGPoint {
        point(from: to, to: from, t: wrappedUnit(flowPhase + seed + 0.68))
    }

    private func midpoint(from: CGPoint, to: CGPoint) -> CGPoint {
        CGPoint(x: (from.x + to.x) * 0.5, y: (from.y + to.y) * 0.5)
    }

    private func point(from: CGPoint, to: CGPoint, t: CGFloat) -> CGPoint {
        CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
    }

    private func wrappedUnit(_ v: CGFloat) -> CGFloat {
        let x = v - floor(v)
        return x < 0 ? x + 1 : x
    }
}

private func linkColor(for throughput: Int) -> Color {
    if throughput >= 320 { return Color.white.opacity(0.90) }
    if throughput >= 160 { return Color.white.opacity(0.76) }
    return Color.white.opacity(0.58)
}

// MARK: - Node Circle

private struct NodeCircle: View {
    let name: String
    let kind: NetworkTopologyView.TopologyNode.Kind
    let isHovered: Bool
    let isSelected: Bool
    let metrics: NetworkTopologyMonitor.NodeMetrics?
    let quality: NetworkTopologyMonitor.ConnectionQuality

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Status dot with quality color
                Circle()
                    .fill(statusColor)
                    .frame(width: isHovered ? 12 : 10, height: isHovered ? 12 : 10)

                // Selection ring
                if kind == .local || isSelected {
                    Circle()
                        .stroke(quality.color.opacity(0.65), lineWidth: isSelected ? 1.4 : 1)
                        .frame(width: isHovered ? 22 : 18, height: isHovered ? 22 : 18)
                }
            }

            Text(name)
                .font(.system(size: 11, weight: kind == .local ? .semibold : .medium, design: .rounded))
                .foregroundStyle(kind == .local || isSelected ? OverlayTheme.textPrimary : OverlayTheme.textSecondary)
                .lineLimit(1)

            if isHovered, let m = metrics {
                HStack(spacing: 4) {
                    if m.isReachable {
                        Text("\(m.latencyMS)ms")
                            .font(.caption2)
                            .foregroundStyle(quality.color)
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(m.throughputMbps)Mbps")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Unreachable")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .animation(.easeOut(duration: 0.18), value: isHovered)
    }

    private var statusColor: Color {
        if kind == .local { return OverlayTheme.accent.opacity(0.95) }
        return quality.color.opacity(metrics?.isReachable == true ? 0.78 : 0.3)
    }
}

// MARK: - Link Badge

private struct LinkBadge: View {
    let icon: String
    let throughputMbps: Int?
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
            if let throughputMbps {
                Text("\(throughputMbps)")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
            }
        }
        .foregroundStyle(color.opacity(0.95))
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(OverlayTheme.panelStrong, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).stroke(OverlayTheme.border.opacity(0.6), lineWidth: 0.7))
    }
}

private struct TrafficDot: View {
    var color: Color = OverlayTheme.accent
    var opacity: Double = 0.85
    var size: CGFloat = 4

    var body: some View {
        Circle()
            .fill(color.opacity(opacity))
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.35), radius: 2, x: 0, y: 0)
    }
}

// MARK: - Node Tooltip

private struct NodeTooltip: View {
    let name: String
    let kind: NetworkTopologyView.TopologyNode.Kind
    let ip: String
    let metrics: NetworkTopologyMonitor.NodeMetrics?
    let quality: NetworkTopologyMonitor.ConnectionQuality

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OverlayTheme.textPrimary)

            Text(ip)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(OverlayTheme.textSecondary)

            HStack(spacing: 6) {
                Text(kindLabel)
                Text("•")
                Text(quality.rawValue)
                    .foregroundStyle(quality.color)
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(OverlayTheme.textSecondary)

            if let m = metrics, m.isReachable {
                HStack(spacing: 6) {
                    Text("\(m.latencyMS) ms")
                    Text("•")
                    Text("\(m.throughputMbps) Mbps")
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(OverlayTheme.textSecondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(OverlayTheme.panelStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(OverlayTheme.border.opacity(0.55), lineWidth: 0.7)
        )
    }

    private var kindLabel: String {
        switch kind {
        case .local: return "local"
        case .paired: return "paired"
        case .discovered: return "discover"
        }
    }
}

#Preview {
    _NetworkTopologyPreview()
        .frame(width: 360, height: 260)
        .padding(24)
}

private struct _NetworkTopologyPreview: View {
    @State private var selectedNodeID: String? = "local"

    var body: some View {
        NetworkTopologyView(
            nodes: [
                .init(id: "local", name: "This Mac", kind: .local, linkType: .ethernet, ipAddress: "127.0.0.1"),
                .init(id: "peer-1", name: "Studio Mac", kind: .paired, linkType: .wifi, ipAddress: "192.168.1.100"),
                .init(id: "peer-2", name: "Lab Mac", kind: .paired, linkType: .thunderbolt, ipAddress: "192.168.1.101"),
                .init(id: "discovered-1", name: "Nearby Mac", kind: .discovered, linkType: .unknown, ipAddress: "192.168.1.102")
            ],
            selectedNodeID: $selectedNodeID
        )
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct ContainerMeshView: View {
    struct MeshNode: Identifiable, Hashable {
        enum Kind: String {
            case proxy = "Load Balancer"
            case service = "Application"
            case database = "Backend / DB"
            case unknown = "Workload"
            
            var icon: String {
                switch self {
                case .proxy: return "arrow.up.and.down.and.sparkles"
                case .service: return "cube.fill"
                case .database: return "cylinder.split.1x2.fill"
                case .unknown: return "square.dashed"
                }
            }
            
            var color: Color {
                switch self {
                case .proxy: return .cyan
                case .service: return .green
                case .database: return .orange
                case .unknown: return .gray
                }
            }
        }
        
        let id: UUID
        let name: String
        let image: String
        let kind: Kind
        let ip: String
    }
    
    let vms: [VirtualMachine]
    @State private var flowPhase: CGFloat = 0
    
    private var meshNodes: [MeshNode] {
        vms.map { vm in
            let img = vm.containerImageReference.lowercased()
            let kind: MeshNode.Kind
            
            if img.contains("nginx") || img.contains("proxy") || img.contains("traefik") || img.contains("caddy") || img.contains("haproxy") || img.contains("gateway") {
                kind = .proxy
            } else if img.contains("mysql") || img.contains("postgre") || img.contains("redis") || img.contains("db") || img.contains("mongo") || img.contains("db") {
                kind = .database
            } else {
                kind = .service
            }
            
            return MeshNode(
                id: vm.id,
                name: vm.name,
                image: vm.containerImageReference,
                kind: kind,
                ip: vm.ipAddress
            )
        }
    }
    
    private var connections: [(from: Int, to: Int)] {
        var result: [(Int, Int)] = []
        let nodes = meshNodes
        let proxies = nodes.indices.filter { nodes[$0].kind == .proxy }
        let services = nodes.indices.filter { nodes[$0].kind == .service }
        let databases = nodes.indices.filter { nodes[$0].kind == .database }
        
        // Match Proxy to Services
        for p in proxies {
            for s in services {
                result.append((p, s))
            }
        }
        
        // Match Services to Databases
        for s in services {
            for d in databases {
                result.append((s, d))
            }
        }
        
        return result
    }
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background Glow
                RadialGradient(
                    colors: [Color.cyan.opacity(0.08), Color.clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: min(geo.size.width, geo.size.height) * 0.6
                )
                
                // Connection Lines
                ForEach(0..<connections.count, id: \.self) { idx in
                    let conn = connections[idx]
                    ConnectionPath(
                        from: position(for: conn.from, in: geo.size),
                        to: position(for: conn.to, in: geo.size),
                        phase: flowPhase
                    )
                    .stroke(
                        meshNodes[conn.from].kind.color.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 6], dashPhase: flowPhase * 10)
                    )
                }
                
                // Nodes
                ForEach(0..<meshNodes.count, id: \.self) { idx in
                    let node = meshNodes[idx]
                    MeshNodeView(node: node)
                        .position(position(for: idx, in: geo.size))
                }
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 10).repeatForever(autoreverses: false)) {
                flowPhase = 1
            }
        }
    }
    
    private func position(for index: Int, in size: CGSize) -> CGPoint {
        let nodes = meshNodes
        guard nodes.count > 0 else { return .zero }
        let node = nodes[index]
        
        let proxies = nodes.filter { $0.kind == .proxy }
        let services = nodes.filter { $0.kind == .service }
        let dbs = nodes.filter { $0.kind == .database }
        
        let x: CGFloat
        let y: CGFloat
        
        switch node.kind {
        case .proxy:
            x = size.width * 0.15
            let i = CGFloat(proxies.firstIndex(of: node) ?? 0)
            y = distribute(index: i, total: CGFloat(proxies.count), height: size.height)
        case .service:
            x = size.width * 0.5
            let i = CGFloat(services.firstIndex(of: node) ?? 0)
            y = distribute(index: i, total: CGFloat(services.count), height: size.height)
        case .database:
            x = size.width * 0.85
            let i = CGFloat(dbs.firstIndex(of: node) ?? 0)
            y = distribute(index: i, total: CGFloat(dbs.count), height: size.height)
        case .unknown:
            x = size.width * 0.5
            y = size.height * 0.9
        }
        
        return CGPoint(x: x, y: y)
    }
    
    private func distribute(index: CGFloat, total: CGFloat, height: CGFloat) -> CGFloat {
        if total <= 1 { return height / 2 }
        let padding: CGFloat = 80
        let available = height - (padding * 2)
        return padding + (index / (total - 1)) * available
    }
}

struct ConnectionPath: Shape {
    let from: CGPoint
    let to: CGPoint
    let phase: CGFloat
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        
        let control1 = CGPoint(x: from.x + (to.x - from.x) * 0.4, y: from.y)
        let control2 = CGPoint(x: from.x + (to.x - from.x) * 0.6, y: to.y)
        
        path.addCurve(to: to, control1: control1, control2: control2)
        return path
    }
}

struct MeshNodeView: View {
    let node: ContainerMeshView.MeshNode
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(node.kind.color.opacity(0.12))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Circle()
                            .stroke(node.kind.color.opacity(0.4), lineWidth: 1)
                    )
                
                Image(systemName: node.kind.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(node.kind.color)
            }
            .shadow(color: node.kind.color.opacity(0.2), radius: 8)
            
            VStack(spacing: 2) {
                Text(node.name)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                
                Text(node.ip)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                
                Text(node.kind.rawValue)
                    .font(.system(size: 7, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(node.kind.color.opacity(0.15), in: Capsule())
                    .foregroundStyle(node.kind.color)
            }
        }
        .frame(width: 100)
    }
}
