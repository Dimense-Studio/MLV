import SwiftUI

/// Minimalist, mesh-style network topology view for WireGuard cluster.
/// - Nodes appear as circles with status, connected by animated lines.
/// - Inspired by exo.lab visual minimalism.
struct NetworkTopologyView: View {
    private let wg = WireGuardManager.shared
    
    @State private var hoveredNodeID: String? = nil
    
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
                // Connections (arcs between all nodes, undirected)
                ForEach(connections) { conn in
                    let fromPoint = position(for: conn.a, in: geo.size)
                    let toPoint = position(for: conn.b, in: geo.size)
                    connectionLine(from: fromPoint,
                                   to: toPoint)
                        .stroke(Color.accentColor.opacity(0.16), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [5, 8]))
                }
                // Nodes
                ForEach(Array(allNodes.enumerated()), id: \.element.id) { index, node in
                    let pos = position(for: index, in: geo.size)
                    NodeCircle(name: node.name, isSelf: node.selfNode, isHovered: hoveredNodeID == node.id)
                        .position(pos)
                        .onHover { hovered in
                            hoveredNodeID = hovered ? node.id : nil
                        }
                        .animation(.easeOut(duration: 0.35), value: hoveredNodeID)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.windowBackgroundColor).opacity(0.001))
        }
    }
    
    // Each node is placed in a circle
    func position(for index: Int, in size: CGSize) -> CGPoint {
        let count = max(1, allNodes.count)
        let radius = min(size.width, size.height) * 0.35
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
    
    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(isSelf ? Color.accentColor : Color.primary.opacity(isHovered ? 0.14 : 0.08))
                .frame(width: isHovered ? 64 : 54, height: isHovered ? 64 : 54)
                .shadow(color: isSelf ? Color.accentColor.opacity(0.25) : .clear, radius: 8, y: 3)
                .overlay(Circle().strokeBorder(isSelf ? Color.accentColor : Color.secondary.opacity(isHovered ? 0.5 : 0.2), lineWidth: isSelf ? 4 : 2))
            Text(name)
                .font(.system(size: isHovered ? 14 : 12, weight: isSelf ? .bold : .medium, design: .rounded))
                .lineLimit(1)
                .foregroundColor(isSelf ? Color.accentColor : .primary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .animation(.snappy, value: isHovered)
    }
}

#Preview {
    NetworkTopologyView()
        .frame(width: 360, height: 260)
        .preferredColorScheme(.dark)
        .padding(40)
}

