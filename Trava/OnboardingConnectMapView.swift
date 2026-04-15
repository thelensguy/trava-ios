//  OnboardingConnectMapView.swift
//  Trava
//
//  Step 1 of 3 — Connect your map data source.

import SwiftUI

struct OnboardingConnectMapView: View {
    var onComplete: () -> Void
    @EnvironmentObject var auth: AuthViewModel

    var body: some View {
        ZStack {
            Color.dsSurface.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {

                    // Nav bar
                    HStack {
                        Text("URBAN ARCHITECT")
                            .font(.dsLabelMd())
                            .foregroundColor(.dsOnSurfaceVariant)
                            .kerning(2)
                        Spacer()
                        Circle()
                            .fill(Color.dsSurfaceContainerHigh)
                            .frame(width: 36, height: 36)
                            .overlay(
                                Image(systemName: "person")
                                    .foregroundColor(.dsOnSurfaceVariant)
                                    .font(.system(size: 14))
                            )
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.top, DS.Spacing.lg)

                    // Step counter — large display number creates editorial anchor
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
                        Text("01")
                            .font(.dsDisplay(size: 64))
                            .foregroundColor(.dsPrimary)
                        Text("/ 03")
                            .font(.dsHeadlineSm())
                            .foregroundColor(.dsOnSurfaceVariant)
                    }
                    .padding(.leading, DS.Spacing.lg)
                    .padding(.top, DS.Spacing.xl)

                    // Headline — asymmetric right margin for editorial feel
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        Text("Map Your\nMovement")
                            .font(.dsDisplay(size: 44))
                            .foregroundColor(.dsOnSurface)
                            .lineSpacing(4)

                        Text("Transform your anonymous city data into a precision architectural blueprint of your life.")
                            .font(.dsBodyMd())
                            .foregroundColor(.dsOnSurfaceVariant)
                            .lineSpacing(5)
                    }
                    .padding(.leading, DS.Spacing.lg)
                    .padding(.trailing, DS.Spacing.xl)
                    .padding(.top, DS.Spacing.sm)

                    // Feature card: Bootstrap Heatmaps
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        HStack(alignment: .center) {
                            Image(systemName: "map.fill")
                                .foregroundColor(.dsPrimary)
                                .font(.system(size: 15))
                            Text("Bootstrap Heatmaps")
                                .font(.dsTitleMd())
                                .foregroundColor(.dsOnSurface)
                            Spacer()
                            HStack(spacing: DS.Spacing.xs) {
                                Circle()
                                    .fill(Color.dsPrimary)
                                    .frame(width: 5, height: 5)
                                Text("Generating Blueprint...")
                                    .font(.dsLabelSm())
                                    .foregroundColor(.dsPrimary)
                            }
                        }
                        Text("Your location history is processed on-device to build activity density layers, revealing how you navigate urban environments — with zero raw data leaving your phone.")
                            .font(.dsBodyMd())
                            .foregroundColor(.dsOnSurfaceVariant)
                            .lineSpacing(4)
                    }
                    .padding(DS.Spacing.md)
                    .background(Color.dsSurfaceContainerLow)
                    .cornerRadius(DS.Radius.md)
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.top, DS.Spacing.xl)

                    // Feature card: Privacy
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        HStack {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundColor(.dsSecondary)
                                .font(.system(size: 15))
                            Text("Architectural Privacy")
                                .font(.dsTitleMd())
                                .foregroundColor(.dsOnSurface)
                            Spacer()
                            Text("VERIFIED")
                                .font(.dsLabelSm())
                                .foregroundColor(.dsSecondary)
                                .padding(.horizontal, DS.Spacing.sm)
                                .padding(.vertical, 3)
                                .background(Color.dsSecondaryContainer.opacity(0.25))
                                .cornerRadius(DS.Radius.sm)
                        }

                        HStack(spacing: DS.Spacing.md) {
                            Label {
                                Text("End-to-End Encryption")
                                    .font(.dsLabelMd())
                                    .foregroundColor(.dsOnSurfaceVariant)
                            } icon: {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.dsOutline)
                                    .font(.system(size: 11))
                            }

                            Label {
                                Text("Auto-delete History")
                                    .font(.dsLabelMd())
                                    .foregroundColor(.dsOnSurfaceVariant)
                            } icon: {
                                Image(systemName: "trash.fill")
                                    .foregroundColor(.dsOutline)
                                    .font(.system(size: 11))
                            }
                        }
                    }
                    .padding(DS.Spacing.md)
                    .background(Color.dsSurfaceContainerLow)
                    .cornerRadius(DS.Radius.md)
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.top, DS.Spacing.md)

                    // CTA section
                    VStack(spacing: DS.Spacing.md) {
                        Button("Connect Google Maps") { onComplete() }
                            .buttonStyle(PrimaryButtonStyle())

                        Button(action: { onComplete() }) {
                            HStack(spacing: DS.Spacing.xs) {
                                Text("I'll set up manually")
                                    .font(.dsLabelLg())
                                    .foregroundColor(.dsOnSurfaceVariant)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 12))
                                    .foregroundColor(.dsOnSurfaceVariant)
                            }
                        }

                        // Ghost button — local-only dev/guest bypass
                        Button(action: { auth.continueAsGuest() }) {
                            Text("Continue without account")
                                .font(.dsLabelLg())
                                .foregroundColor(.dsOnSurfaceVariant)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, DS.Spacing.sm)
                        }
                        .ghostBorder()

                        Text("By connecting, you agree to our Precision Architect Data Protocol & Terms")
                            .font(.dsLabelSm())
                            .foregroundColor(.dsOutline)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.top, DS.Spacing.xxl)
                    .padding(.bottom, DS.Spacing.xxl)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    OnboardingConnectMapView(onComplete: {})
        .environmentObject(AuthViewModel())
}
