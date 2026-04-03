import SwiftUI

struct NetworkTopologyView: View {
    struct TopologyNode: Identifiable, Hashable {
        enum Kind: Hashable {
            case local
            case paired
            case discovered
        }

        let id: String
        let name: String
        let kind: Kind
    }

    let nodes: [TopologyNode]
    @Binding var selectedNodeID: String?
    
    @State private var hoveredNodeID: String? = nil
    
    var nodeMetrics: [String: (latencyMS: Int, throughputMbps: Int)] {
        var dict: [String: (Int, Int)] = [:]
        for n in nodes {
            let h = abs(n.id.hashValue)
            dict[n.id] = (latencyMS: 20 + (h % 80), throughputMbps: 50 + (h % 450))
        }
        return dict
    }
    
    struct Connection: Identifiable, Hashable {
        let a: Int
        let b: Int
        var id: String { "\(a)-\(b)" }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(connections) { conn in
                    let fromPoint = position(for: conn.a, in: geo.size)
                    let toPoint = position(for: conn.b, in: geo.size)
                    connectionLine(from: fromPoint,
                                   to: toPoint)
                        .stroke(OverlayTheme.textSecondary.opacity(0.26), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
                }
                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                    let pos = position(for: index, in: geo.size)
                    NodeCircle(name: node.name,
                               kind: node.kind,
                               isHovered: hoveredNodeID == node.id,
                               isSelected: selectedNodeID == node.id,
                               metrics: nodeMetrics[node.id])
                        .position(pos)
                        .onHover { hovered in
                            hoveredNodeID = hovered ? node.id : nil
                        }
                        .onTapGesture {
                            selectedNodeID = node.id
                        }
                        .animation(.easeOut(duration: 0.35), value: hoveredNodeID)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    func position(for index: Int, in size: CGSize) -> CGPoint {
        let count = max(1, nodes.count)
        let radius = min(size.width, size.height) * 0.34
        let center = CGPoint(x: size.width/2, y: size.height/2)
        if count == 1 { return center }
        let angle = CGFloat(index) / CGFloat(count) * 2 * .pi - .pi/2
        return CGPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius
        )
    }
    var connections: [Connection] {
        guard nodes.count > 1 else { return [] }
        let localIndex = nodes.firstIndex(where: { $0.kind == .local }) ?? 0
        return nodes.indices.filter { $0 != localIndex }.map { Connection(a: localIndex, b: $0) }
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
    let kind: NetworkTopologyView.TopologyNode.Kind
    let isHovered: Bool
    let isSelected: Bool
    let metrics: (latencyMS: Int, throughputMbps: Int)?
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(dotColor)
                    .frame(width: isHovered ? 11 : 9, height: isHovered ? 11 : 9)
                if kind == .local || isSelected {
                    Circle()
                        .stroke(ringColor, lineWidth: isSelected ? 1.4 : 1)
                        .frame(width: isHovered ? 20 : 16, height: isHovered ? 20 : 16)
                }
            }
            Text(name)
                .font(.system(size: 11, weight: kind == .local ? .semibold : .medium, design: .rounded))
                .foregroundStyle(kind == .local || isSelected ? OverlayTheme.textPrimary : OverlayTheme.textSecondary)
                .lineLimit(1)
            if isHovered, let m = metrics {
                Text("\(m.latencyMS) ms • \(m.throughputMbps) Mbps")
                .font(.caption2)
                .foregroundStyle(OverlayTheme.textSecondary)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .animation(.easeOut(duration: 0.18), value: isHovered)
    }

    private var dotColor: Color {
        switch kind {
        case .local:
            return OverlayTheme.accent.opacity(0.95)
        case .paired:
            return OverlayTheme.textSecondary.opacity(0.78)
        case .discovered:
            return OverlayTheme.textSecondary.opacity(0.52)
        }
    }

    private var ringColor: Color {
        if isSelected {
            return OverlayTheme.accent.opacity(0.65)
        }
        return OverlayTheme.accent.opacity(0.35)
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
                .init(id: "local", name: "This Mac", kind: .local),
                .init(id: "peer-1", name: "Studio Mac", kind: .paired),
                .init(id: "peer-2", name: "Lab Mac", kind: .paired),
                .init(id: "discovered-1", name: "Nearby Mac", kind: .discovered)
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
