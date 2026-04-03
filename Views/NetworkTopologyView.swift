import SwiftUI

/// Minimalist, mesh-style network topology view for WireGuard cluster.
/// - Nodes appear as circles with status, connected by animated lines.
/// - Inspired by exo.lab visual minimalism.
struct NetworkTopologyView: View {
    private let wg = WireGuardManager.shared
    
    @State private var hoveredNodeID: String? = nil
    
    // Placeholder metrics; replace with real data from your manager when available
    var nodeMetrics: [String: (latencyMS: Int, throughputMbps: Int)] {
        var dict: [String: (Int, Int)] = [:]
        for n in allNodes {
            // simple deterministic placeholders based on id hash
            let h = abs(n.id.hashValue)
            dict[n.id] = (latencyMS: 20 + (h % 80), throughputMbps: 50 + (h % 450))
        }
        return dict
    }
    
    var myNode: WireGuardManager.HostInfo {
        wg.hostInfo
    }
    var peers: [WireGuardManager.Peer] {
        wg.peers
    }
    var allNodes: [AnyNode] {
        [AnyNode(id: myNode.id, name: myNode.name, selfNode: true)] +
        peers.map { AnyNode(id: $0.id, name: $0.name, selfNode: false) }
    }
    
    struct AnyNode: Identifiable {
        let id: String
        let name: String
        let selfNode: Bool
    }
    
    struct Connection: Identifiable, Hashable {
        let a: Int
        let b: Int
        var id: String { "\(a)-\(b)" }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 1)
                    )
                    .padding(8)
                
                ForEach(connections) { conn in
                    let fromPoint = position(for: conn.a, in: geo.size)
                    let toPoint = position(for: conn.b, in: geo.size)
                    connectionLine(from: fromPoint,
                                   to: toPoint)
                        .stroke(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round, dash: [3, 10]))
                    
                    let midPoint = CGPoint(x: (fromPoint.x + toPoint.x) / 2, y: (fromPoint.y + toPoint.y) / 2)
                    if let peerID = allNodes[safe: conn.b]?.id, let m = nodeMetrics[peerID] {
                        ConnectionBadge(text: "\(m.latencyMS) ms")
                            .position(midPoint)
                    }
                }
                ForEach(Array(allNodes.enumerated()), id: \.element.id) { index, node in
                    let pos = position(for: index, in: geo.size)
                    NodeCircle(name: node.name,
                               isSelf: node.selfNode,
                               isHovered: hoveredNodeID == node.id,
                               metrics: nodeMetrics[node.id])
                        .position(pos)
                        .onHover { hovered in
                            hoveredNodeID = hovered ? node.id : nil
                        }
                        .animation(.easeOut(duration: 0.35), value: hoveredNodeID)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.clear)
        }
    }
    
    // Each node is placed in a circle
    func position(for index: Int, in size: CGSize) -> CGPoint {
        let count = max(1, allNodes.count)
        let radius = min(size.width, size.height) * 0.38
        let center = CGPoint(x: size.width/2, y: size.height/2)
        if count == 1 { return center }
        let angle = CGFloat(index) / CGFloat(count) * 2 * .pi - .pi/2
        return CGPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius
        )
    }
    // For direct lines, connect self to every peer
    var connections: [Connection] {
        guard allNodes.count > 1 else { return [] }
        return allNodes.indices.dropFirst().map { Connection(a: 0, b: $0) }
    }
    func connectionLine(from: CGPoint, to: CGPoint) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        return path
    }
}

private struct NodeCircle: View {
    let name: String
    let isSelf: Bool
    let isHovered: Bool
    let metrics: (latencyMS: Int, throughputMbps: Int)?
    
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(isSelf ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.08))
                    .overlay(Circle().strokeBorder(isSelf ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: isSelf ? 2 : 1))
                    .frame(width: isHovered ? 60 : 54, height: isHovered ? 60 : 54)
            }
            Text(name)
                .font(.system(size: 11, weight: isSelf ? .semibold : .regular, design: .rounded))
                .foregroundStyle(isSelf ? Color.primary : .secondary)
                .lineLimit(1)
            if let m = metrics {
                Text("\(m.latencyMS) ms • \(m.throughputMbps) Mbps")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(6)
        .animation(.easeOut(duration: 0.18), value: isHovered)
    }
}

private struct ConnectionBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.background, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 1))
            .foregroundStyle(.secondary)
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview {
    NetworkTopologyView()
        .frame(width: 360, height: 260)
        .padding(24)
}
