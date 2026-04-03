import SwiftUI

struct NetworkTopologyView: View {
    enum LinkType: Hashable {
        case wifi
        case ethernet
        case thunderbolt
        case mixed
        case unknown

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
        enum Kind: Hashable {
            case local
            case paired
            case discovered
        }

        let id: String
        let name: String
        let kind: Kind
        let linkType: LinkType
    }

    let nodes: [TopologyNode]
    @Binding var selectedNodeID: String?
    
    @State private var hoveredNodeID: String? = nil
    @State private var flowPhase: CGFloat = 0
    
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

                ForEach(connections) { conn in
                    let fromPoint = position(for: conn.a, in: geo.size)
                    let toPoint = position(for: conn.b, in: geo.size)
                    let throughput = nodes[safe: conn.b].flatMap { nodeMetrics[$0.id]?.throughputMbps } ?? 0
                    let trafficColor = linkColor(for: throughput)
                    connectionLine(from: fromPoint,
                                   to: toPoint)
                        .stroke(OverlayTheme.textSecondary.opacity(0.28), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))

                    connectionLine(from: fromPoint, to: toPoint)
                        .stroke(trafficColor.opacity(0.16), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

                    let seed = CGFloat(abs(conn.id.hashValue % 100)) / 100
                    let t1 = wrappedUnit(flowPhase + seed)
                    let t2 = wrappedUnit(flowPhase + seed + 0.42)
                    let pulse1 = point(from: fromPoint, to: toPoint, t: t1)
                    let pulse2 = point(from: fromPoint, to: toPoint, t: t2)
                    let reverse1 = point(from: toPoint, to: fromPoint, t: wrappedUnit(flowPhase + seed + 0.2))
                    let reverse2 = point(from: toPoint, to: fromPoint, t: wrappedUnit(flowPhase + seed + 0.68))

                    TrafficDot(color: trafficColor, opacity: 0.85, size: 4)
                        .position(pulse1)
                    TrafficDot(color: trafficColor, opacity: 0.45, size: 3)
                        .position(pulse2)
                    TrafficDot(color: trafficColor.opacity(0.8), opacity: 0.7, size: 3.5)
                        .position(reverse1)
                    TrafficDot(color: trafficColor.opacity(0.7), opacity: 0.35, size: 2.8)
                        .position(reverse2)

                    if let remote = nodes[safe: conn.b] {
                        LinkBadge(
                            icon: remote.linkType.icon,
                            throughputMbps: nodeMetrics[remote.id]?.throughputMbps,
                            color: trafficColor
                        )
                            .position(CGPoint(x: (fromPoint.x + toPoint.x) * 0.5, y: (fromPoint.y + toPoint.y) * 0.5))
                    }
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

                if let hoveredNodeID,
                   let hoveredIndex = nodes.firstIndex(where: { $0.id == hoveredNodeID }),
                   let hoveredNode = nodes[safe: hoveredIndex] {
                    let anchor = position(for: hoveredIndex, in: geo.size)
                    NodeTooltip(
                        name: hoveredNode.name,
                        kind: hoveredNode.kind,
                        latencyMS: nodeMetrics[hoveredNode.id]?.latencyMS,
                        throughputMbps: nodeMetrics[hoveredNode.id]?.throughputMbps
                    )
                    .position(x: min(max(anchor.x + 62, 90), geo.size.width - 90),
                              y: min(max(anchor.y - 26, 34), geo.size.height - 34))
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.35), value: nodes.map(\.id))
            .onAppear {
                guard flowPhase == 0 else { return }
                withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
                    flowPhase = 1
                }
            }
        }
    }
    
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

        let nodeHash = abs(nodes[index].id.hashValue)
        let jitter = CGFloat(nodeHash % 17) / 100.0
        let baseAngle = CGFloat(ringIndex) / CGFloat(ringCount) * 2 * .pi - .pi / 2
        let angle = baseAngle + jitter
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
    func connectionLine(from: CGPoint, to: CGPoint) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        return path
    }

    private func point(from: CGPoint, to: CGPoint, t: CGFloat) -> CGPoint {
        CGPoint(
            x: from.x + ((to.x - from.x) * t),
            y: from.y + ((to.y - from.y) * t)
        )
    }

    private func wrappedUnit(_ v: CGFloat) -> CGFloat {
        let x = v - floor(v)
        return x < 0 ? x + 1 : x
    }

    private func linkColor(for throughput: Int) -> Color {
        if throughput >= 320 { return Color.white.opacity(0.90) }
        if throughput >= 160 { return Color.white.opacity(0.76) }
        return Color.white.opacity(0.58)
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
                    .frame(width: isHovered ? 12 : 10, height: isHovered ? 12 : 10)
                if kind == .local || isSelected {
                    Circle()
                        .stroke(ringColor, lineWidth: isSelected ? 1.4 : 1)
                        .frame(width: isHovered ? 22 : 18, height: isHovered ? 22 : 18)
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

private struct NodeTooltip: View {
    let name: String
    let kind: NetworkTopologyView.TopologyNode.Kind
    let latencyMS: Int?
    let throughputMbps: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OverlayTheme.textPrimary)
            HStack(spacing: 6) {
                Text(kindLabel)
                if let latencyMS {
                    Text("\(latencyMS) ms")
                }
                if let throughputMbps {
                    Text("\(throughputMbps) Mbps")
                }
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(OverlayTheme.textSecondary)
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
                .init(id: "local", name: "This Mac", kind: .local, linkType: .ethernet),
                .init(id: "peer-1", name: "Studio Mac", kind: .paired, linkType: .wifi),
                .init(id: "peer-2", name: "Lab Mac", kind: .paired, linkType: .thunderbolt),
                .init(id: "discovered-1", name: "Nearby Mac", kind: .discovered, linkType: .unknown)
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
