//
//  NavigationDetailsView.swift
//  BikeComputer
//
//  Navigation instruction display view
//

import SwiftUI

struct NavigationDetailsView: View {
    let iconID: Int
    let distanceToManeuver: Int
    let instruction: String
    let isCompact: Bool
    
    init(iconID: Int, distanceToManeuver: Int, instruction: String, isCompact: Bool = false) {
        self.iconID = iconID
        self.distanceToManeuver = distanceToManeuver
        self.instruction = instruction
        self.isCompact = isCompact
    }
    
    var body: some View {
        VStack(spacing: isCompact ? 15 : 20) {
            // Arrow Icon
            Image(systemName: NavigationIcon.icon(for: iconID))
                .font(.system(size: isCompact ? 60 : 80))
                .foregroundColor(.blue)
            
            // Distance
            Text("\(distanceToManeuver)")
                .font(.system(size: isCompact ? 56 : 72, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            
            Text("meters")
                .font(isCompact ? .title3 : .title2)
                .foregroundColor(.secondary)
            
            // Instruction
            Text(instruction)
                .font(isCompact ? .title3 : .title2)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .lineLimit(isCompact ? 2 : nil)
        }
    }
}

// MARK: - Navigation Icon Mapping

enum NavigationIcon {
    static func icon(for iconID: Int) -> String {
        switch iconID {
        case NavigationIconID.left: return "arrow.turn.up.left"
        case NavigationIconID.right: return "arrow.turn.up.right"
        case NavigationIconID.uTurn: return "arrow.uturn.left"
        case NavigationIconID.straight: return "arrow.up"
        default: return "arrow.up"
        }
    }
}
