//
//  ColorView.swift
//
//  Copyright © 2020 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Cocoa

internal class ColorView: DraggingDestinationView {

    required init?(coder: NSCoder) {
        super.init(coder: coder)

        setupView()
    }

    init(frame: NSRect, backgroundColor: NSColor? = nil, cornerRadius: CGFloat = 0, roundedCorners: RoundedCorners = .all, borderColor: NSColor? = nil, borderWidth: CGFloat = 0, interceptClickEvents: Bool = false) {
        super.init(frame: frame)

        self.translatesAutoresizingMaskIntoConstraints = false
        self.backgroundColor = backgroundColor
        self.cornerRadius = cornerRadius
        self.roundedCorners = roundedCorners
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        self.interceptClickEvents = interceptClickEvents

        setupView()
    }

    /// When `true` colors will be reserved agains the `effectiveAppearance` value.
    /// Otherwise, we'll rely on `NSApp.effectiveAppearance`
    var resolvesStyleWithEffectiveAppearance: Bool = false {
        didSet {
            guard resolvesStyleWithEffectiveAppearance != oldValue else {
                return
            }

            updateShape()
        }
    }

    // Fill + border are drawn as a single CAShapeLayer path so they share identical
    // geometry — avoids the antialiasing seam where CALayer.backgroundColor bleeds
    // past a CALayer.borderColor stroke at rounded corners.
    private let shapeLayer = CAShapeLayer()

    @IBInspectable var backgroundColor: NSColor? = NSColor.clear {
        didSet {
            updateShape()
        }
    }

    @IBInspectable var cornerRadius: CGFloat = 0 {
        didSet {
            updateShape()
        }
    }

    var roundedCorners: RoundedCorners = .all {
        didSet {
            updateShape()
        }
    }

    @IBInspectable var borderColor: NSColor? {
        didSet {
            updateShape()
        }
    }

    @IBInspectable var borderWidth: CGFloat = 0 {
        didSet {
            updateShape()
        }
    }

    @IBInspectable var interceptClickEvents: Bool = false

    func setupView() {
        self.wantsLayer = true
        layer?.addSublayer(shapeLayer)
        updateShape()
    }

    override func layout() {
        super.layout()
        updateShape()
    }

    override func updateLayer() {
        super.updateLayer()
        updateShape()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateShape()
    }

    private func updateShape() {
        let inset = borderWidth * 0.5
        let shapeFrame = bounds.insetBy(dx: inset, dy: inset)

        // Unlike a view's backing layer, a manually-added sublayer keeps CoreAnimation's
        // implicit actions enabled, so path/frame/color changes cross-fade over ~0.25s.
        // Disable actions for the whole update so the shape changes instantly.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // A manually-added sublayer does not inherit contentsScale from the view's
        // backing layer, so it defaults to 1.0 and renders the path at half resolution
        // (pixellated) on Retina displays. Match the window's backing scale factor.
        shapeLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.defaultBackingScaleFactor
        shapeLayer.frame = bounds
        shapeLayer.path = roundedPath(in: shapeFrame)
        shapeLayer.lineWidth = borderWidth

        NSAppearance.withAppearance(targetAppearance) {
            shapeLayer.fillColor = backgroundColor?.cgColor
            shapeLayer.strokeColor = borderColor?.cgColor
        }
    }

    private var targetAppearance: NSAppearance? {
        resolvesStyleWithEffectiveAppearance ? effectiveAppearance : nil
    }

    private func roundedPath(in rect: NSRect) -> CGPath {
        let tl = roundedCorners.contains(.topLeft) ? cornerRadius : 0
        let tr = roundedCorners.contains(.topRight) ? cornerRadius : 0
        let bl = roundedCorners.contains(.bottomLeft) ? cornerRadius : 0
        let br = roundedCorners.contains(.bottomRight) ? cornerRadius : 0

        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + bl))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX + tl, y: rect.maxY), radius: tl)
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY - tr), radius: tr)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + br))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX - br, y: rect.minY), radius: br)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.minY + bl), radius: bl)
        path.closeSubpath()
        return path
    }

    // MARK: - Click Event Interception

    override func mouseDown(with event: NSEvent) {
        if !interceptClickEvents {
            super.mouseDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !interceptClickEvents {
            super.mouseUp(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if !interceptClickEvents {
            super.mouseDragged(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if !interceptClickEvents {
            super.rightMouseDown(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if !interceptClickEvents {
            super.otherMouseDown(with: event)
        }
    }
}

struct RoundedCorners: OptionSet {
    let rawValue: Int

    static let topLeft = RoundedCorners(rawValue: 1 << 0)
    static let topRight = RoundedCorners(rawValue: 1 << 1)
    static let bottomLeft = RoundedCorners(rawValue: 1 << 2)
    static let bottomRight = RoundedCorners(rawValue: 1 << 3)

    static let all: RoundedCorners = [.topLeft, .topRight, .bottomLeft, .bottomRight]

    var cornerMask: CACornerMask {
        var mask: CACornerMask = []
        if contains(.topLeft) {
            mask.insert(.layerMinXMaxYCorner)
        }

        if contains(.topRight) {
            mask.insert(.layerMaxXMaxYCorner)
        }

        if contains(.bottomLeft) {
            mask.insert(.layerMinXMinYCorner)
        }

        if contains(.bottomRight) {
            mask.insert(.layerMaxXMinYCorner)
        }

        return mask
    }
}
