//
//  MusicControlButton.swift
//  PacerRun
//
//  Quick-access button that navigates to the system Now Playing
//  screen. On watchOS, third-party apps cannot directly send
//  play/pause/skip commands to other apps' audio sessions.
//  The system Now Playing screen is Apple's supported interface
//  for controlling music during a workout.
//
//  Tapping this button opens the system NowPlayingView,
//  where the user controls music, then taps Back to return
//  to PacerRun's controls page.
//

import SwiftUI
import WatchKit

struct MusicControlButton: View {

    var body: some View {
        NavigationLink {
            // Apple's built-in Now Playing controls for watchOS
            NowPlayingView()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(.system(size: 14))
                Text("Now Playing")
                    .font(.system(size: 13, weight: .bold,
                                  design: .rounded))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.purple.opacity(0.7))
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        MusicControlButton()
    }
}
