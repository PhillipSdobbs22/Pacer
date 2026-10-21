//
//  FeelingRatingView.swift
//  PacerRun
//
//  Post-workout feeling rating — GREAT (3), NOT BAD (2), BAD (1).
//  Must be selected before the workout is saved.
//

import SwiftUI

struct FeelingRatingView: View {

    let onRate: (Int) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("How did it feel?")
                .font(.system(size: 16, weight: .bold,
                              design: .rounded))
                .foregroundColor(.white)

            Button {
                onRate(3)
            } label: {
                HStack {
                    Text("😊")
                        .font(.system(size: 24))
                    Text("GREAT")
                        .font(.system(size: 16, weight: .bold,
                                      design: .rounded))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)

            Button {
                onRate(2)
            } label: {
                HStack {
                    Text("😐")
                        .font(.system(size: 24))
                    Text("NOT BAD")
                        .font(.system(size: 16, weight: .bold,
                                      design: .rounded))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)

            Button {
                onRate(1)
            } label: {
                HStack {
                    Text("😩")
                        .font(.system(size: 24))
                    Text("BAD")
                        .font(.system(size: 16, weight: .bold,
                                      design: .rounded))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.horizontal, 8)
    }
}

#Preview {
    FeelingRatingView { rating in
        print("Rated: \(rating)")
    }
}
