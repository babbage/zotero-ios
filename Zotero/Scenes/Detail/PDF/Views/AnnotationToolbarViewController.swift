//
//  AnnotationToolbarViewController.swift
//  Zotero
//
//  Created by Michal Rentka on 31.10.2022.
//  Copyright © 2022 Corporation for Digital Scholarship. All rights reserved.
//

#if PDFENABLED

import UIKit

import CocoaLumberjackSwift
import PSPDFKit
import RxSwift

struct AnnotationToolOptions: OptionSet {
    typealias RawValue = Int8

    let rawValue: Int8

    init(rawValue: Int8) {
        self.rawValue = rawValue
    }

    static let stylus = AnnotationToolOptions(rawValue: 1 << 0)
}

protocol AnnotationToolbarDelegate: AnyObject {
    var activeAnnotationColor: UIColor { get }
    var activeAnnotationTool: PSPDFKit.Annotation.Tool? { get }

    func toggle(tool: PSPDFKit.Annotation.Tool, options: AnnotationToolOptions)
    func showInkSettings(sender: UIView)
    func showEraserSettings(sender: UIView)
    func showColorPicker(sender: UIButton)
    func closeAnnotationToolbar()
}

class AnnotationToolbarViewController: UIViewController {
    enum Rotation {
        case horizontal, vertical
    }

    static let size: CGFloat = 52
    private let disposeBag: DisposeBag

    private weak var stackView: UIStackView!
    private weak var noteButton: CheckboxButton!
    private weak var highlightButton: CheckboxButton!
    private weak var areaButton: CheckboxButton!
    private weak var inkButton: CheckboxButton!
    private weak var eraserButton: CheckboxButton!
    private weak var colorPickerButton: UIButton!
    private weak var additionalStackView: UIStackView!
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private var handleTop: NSLayoutConstraint!
    private var handleLeading: NSLayoutConstraint!
    private weak var additionalTrailing: NSLayoutConstraint!
    private weak var additionalBottom: NSLayoutConstraint!
    private weak var containerTop: NSLayoutConstraint!
    private weak var containerLeading: NSLayoutConstraint!
    private var containerBottom: NSLayoutConstraint!
    private var containerTrailing: NSLayoutConstraint!
    private var containerToAdditionalVertical: NSLayoutConstraint!
    private var containerToAdditionalHorizontal: NSLayoutConstraint!
    private var rotation: Rotation
    weak var delegate: AnnotationToolbarDelegate?
    private var lastGestureRecognizerTouch: UITouch?

    init(rotation: Rotation) {
        self.rotation = rotation
        self.disposeBag = DisposeBag()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        self.view.backgroundColor = Asset.Colors.navbarBackground.color

        self.setupViews()
        self.set(rotation: self.rotation)
        self.view.layoutIfNeeded()
    }

    func set(selected: Bool, to tool: PSPDFKit.Annotation.Tool) {
        switch tool {
        case .highlight:
            self.highlightButton.isSelected = selected
        case .note:
            self.noteButton.isSelected = selected
        case .square:
            self.areaButton.isSelected = selected
        case .ink:
            self.inkButton.isSelected = selected
        case .eraser:
            self.eraserButton.isSelected = selected
        default: break
        }
    }

    func set(rotation: Rotation) {
        self.view.layer.cornerRadius = 8
        self.view.layer.masksToBounds = false

        switch rotation {
        case .vertical:
            self.heightConstraint.isActive = false
            self.handleTop.isActive = false
            self.containerBottom.isActive = false
            self.containerToAdditionalHorizontal.isActive = false
            self.widthConstraint.isActive = true
            self.handleLeading.isActive = true
            self.containerTrailing.isActive = true
            self.containerToAdditionalVertical.isActive = true

            self.stackView.axis = .vertical
            self.additionalStackView.axis = .vertical

            self.additionalBottom.constant = 8
            self.additionalTrailing.constant = 0
            self.containerLeading.constant = 8
            self.containerTop.constant = 15

        case .horizontal:
            self.widthConstraint.isActive = false
            self.handleLeading.isActive = false
            self.containerTrailing.isActive = false
            self.containerToAdditionalVertical.isActive = false
            self.handleTop.isActive = true
            self.containerBottom.isActive = true
            self.containerToAdditionalHorizontal.isActive = true
            self.heightConstraint.isActive = true

            self.stackView.axis = .horizontal
            self.additionalStackView.axis = .horizontal

            self.additionalBottom.constant = 0
            self.additionalTrailing.constant = 15
            self.containerLeading.constant = 20
            self.containerTop.constant = 8
        }
    }

    private var currentAnnotationOptions: AnnotationToolOptions {
        if self.lastGestureRecognizerTouch?.type == .stylus {
            return .stylus
        }
        return []
    }

    private func createButtons() -> [UIView] {
        let symbolConfig = UIImage.SymbolConfiguration(scale: .large)

        let highlight = CheckboxButton(type: .custom)
        highlight.accessibilityLabel = L10n.Accessibility.Pdf.highlightAnnotationTool
        highlight.setImage(Asset.Images.Annotations.highlighterLarge.image.withRenderingMode(.alwaysTemplate), for: .normal)
        highlight.tintColor = Asset.Colors.zoteroBlueWithDarkMode.color
        highlight.rx.controlEvent(.touchDown)
                 .subscribe(with: self, onNext: { `self`, _ in
                     self.delegate?.toggle(tool: .highlight, options: self.currentAnnotationOptions)
                 })
                 .disposed(by: self.disposeBag)
        self.highlightButton = highlight

        let note = CheckboxButton(type: .custom)
        note.accessibilityLabel = L10n.Accessibility.Pdf.noteAnnotationTool
        note.setImage(Asset.Images.Annotations.noteLarge.image.withRenderingMode(.alwaysTemplate), for: .normal)
        note.tintColor = Asset.Colors.zoteroBlueWithDarkMode.color
        note.rx.controlEvent(.touchDown)
            .subscribe(with: self, onNext: { `self`, _ in
                self.delegate?.toggle(tool: .note, options: self.currentAnnotationOptions)
            })
            .disposed(by: self.disposeBag)
        self.noteButton = note

        let area = CheckboxButton(type: .custom)
        area.accessibilityLabel = L10n.Accessibility.Pdf.imageAnnotationTool
        area.setImage(Asset.Images.Annotations.areaLarge.image.withRenderingMode(.alwaysTemplate), for: .normal)
        area.tintColor = Asset.Colors.zoteroBlueWithDarkMode.color
        area.rx.controlEvent(.touchDown)
            .subscribe(with: self, onNext: { `self`, _ in
                self.delegate?.toggle(tool: .square, options: self.currentAnnotationOptions)
            })
            .disposed(by: self.disposeBag)
        self.areaButton = area

        let inkLongPress = UILongPressGestureRecognizer()
        inkLongPress.delegate = self
        inkLongPress.rx.event
                    .subscribe(with: self, onNext: { `self`, recognizer in
                        if recognizer.state == .began, let view = recognizer.view {
                            self.delegate?.showInkSettings(sender: view)
                            if self.delegate?.activeAnnotationTool != .ink {
                                self.delegate?.toggle(tool: .ink, options: self.currentAnnotationOptions)
                            }
                        }
                    })
                    .disposed(by: self.disposeBag)

        let inkTap = UITapGestureRecognizer()
        inkTap.delegate = self
        inkTap.rx.event
              .subscribe(with: self, onNext: { `self`, _ in
                  self.delegate?.toggle(tool: .ink, options: self.currentAnnotationOptions)
              })
              .disposed(by: self.disposeBag)
        inkTap.require(toFail: inkLongPress)

        let ink = CheckboxButton(type: .custom)
        ink.accessibilityLabel = L10n.Accessibility.Pdf.inkAnnotationTool
        ink.setImage(Asset.Images.Annotations.inkLarge.image.withRenderingMode(.alwaysTemplate), for: .normal)
        ink.tintColor = Asset.Colors.zoteroBlueWithDarkMode.color
        ink.addGestureRecognizer(inkLongPress)
        ink.addGestureRecognizer(inkTap)
        self.inkButton = ink

        let eraserLongPress = UILongPressGestureRecognizer()
        eraserLongPress.delegate = self
        eraserLongPress.rx.event
                       .subscribe(with: self, onNext: { `self`, recognizer in
                           if recognizer.state == .began, let view = recognizer.view {
                               self.delegate?.showEraserSettings(sender: view)
                               if self.delegate?.activeAnnotationTool != .eraser {
                                   self.delegate?.toggle(tool: .eraser, options: self.currentAnnotationOptions)
                               }
                           }
                       })
                       .disposed(by: self.disposeBag)

        let eraserTap = UITapGestureRecognizer()
        eraserTap.delegate = self
        eraserTap.rx.event
              .subscribe(with: self, onNext: { `self`, _ in
                  self.delegate?.toggle(tool: .eraser, options: self.currentAnnotationOptions)
              })
              .disposed(by: self.disposeBag)
        eraserTap.require(toFail: eraserLongPress)

        let eraser = CheckboxButton(type: .custom)
        eraser.accessibilityLabel = L10n.Accessibility.Pdf.eraserAnnotationTool
        eraser.setImage(Asset.Images.Annotations.eraserLarge.image.withRenderingMode(.alwaysTemplate), for: .normal)
        eraser.tintColor = Asset.Colors.zoteroBlueWithDarkMode.color
        eraser.addGestureRecognizer(eraserLongPress)
        eraser.addGestureRecognizer(eraserTap)
        self.eraserButton = eraser

        [highlight, note, area, ink, eraser].forEach { button in
            button.adjustsImageWhenHighlighted = false
            button.selectedBackgroundColor = Asset.Colors.zoteroBlue.color
            button.selectedTintColor = .white
            button.layer.cornerRadius = 4
            button.layer.masksToBounds = true
        }

        let picker = UIButton()
        picker.accessibilityLabel = L10n.Accessibility.Pdf.colorPicker
        picker.setImage(UIImage(systemName: "circle.fill", withConfiguration: symbolConfig), for: .normal)
        picker.tintColor = self.delegate?.activeAnnotationColor
        picker.rx.controlEvent(.touchUpInside)
              .subscribe(with: self, onNext: { `self`, _ in
                  self.delegate?.showColorPicker(sender: self.colorPickerButton)
              })
              .disposed(by: self.disposeBag)
        self.colorPickerButton = picker

        NSLayoutConstraint.activate([
            highlight.widthAnchor.constraint(equalTo: highlight.heightAnchor),
            note.widthAnchor.constraint(equalTo: note.heightAnchor),
            area.widthAnchor.constraint(equalTo: area.heightAnchor),
            ink.widthAnchor.constraint(equalTo: ink.heightAnchor),
            picker.widthAnchor.constraint(equalTo: picker.heightAnchor),
            eraser.widthAnchor.constraint(equalTo: eraser.heightAnchor)
        ])

        return [highlight, note, area, ink, eraser, picker]
    }

    private func createAdditionalItems() -> [UIView] {
        let close = UIButton(type: .custom)
        close.setImage(UIImage(systemName: "xmark.circle", withConfiguration: UIImage.SymbolConfiguration(scale: .large)), for: .normal)
        close.tintColor = Asset.Colors.zoteroBlueWithDarkMode.color
        close.widthAnchor.constraint(equalTo: close.heightAnchor).isActive = true
        close.rx.controlEvent(.touchUpInside)
             .subscribe(with: self, onNext: { `self`, _ in
                 self.delegate?.closeAnnotationToolbar()
             })
             .disposed(by: self.disposeBag)

        let handle = UIImageView(image: UIImage(systemName: "line.3.horizontal", withConfiguration: UIImage.SymbolConfiguration(scale: .large)))
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.contentMode = .center
        handle.tintColor = Asset.Colors.zoteroBlueWithDarkMode.color

        return [close, handle]
    }

    private func setupViews() {
        self.widthConstraint = self.view.widthAnchor.constraint(equalToConstant: AnnotationToolbarViewController.size)
        self.heightConstraint = self.view.heightAnchor.constraint(equalToConstant: AnnotationToolbarViewController.size)

        let stackView = UIStackView(arrangedSubviews: self.createButtons())
        stackView.axis = .vertical
        stackView.spacing = 8
        stackView.distribution = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(stackView)

        let additionalStackView = UIStackView(arrangedSubviews: self.createAdditionalItems())
        additionalStackView.axis = .vertical
        additionalStackView.spacing = 0
        additionalStackView.distribution = .fill
        additionalStackView.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(additionalStackView)

        self.containerBottom = self.view.bottomAnchor.constraint(equalTo: stackView.bottomAnchor, constant: 8)
        self.containerTrailing = self.view.trailingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: 8)
        self.handleTop = self.view.topAnchor.constraint(equalTo: additionalStackView.topAnchor)
        self.handleLeading = self.view.leadingAnchor.constraint(equalTo: additionalStackView.leadingAnchor)
        self.containerToAdditionalVertical = additionalStackView.topAnchor.constraint(equalTo: stackView.bottomAnchor, constant: 50)
        self.containerToAdditionalHorizontal = additionalStackView.leadingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: 50)
        let containerTop = stackView.topAnchor.constraint(equalTo: self.view.topAnchor, constant: 15)
        let containerLeading = stackView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 15)
        let additionalBottom = self.view.bottomAnchor.constraint(equalTo: additionalStackView.bottomAnchor)
        let additionalTrailing = self.view.trailingAnchor.constraint(equalTo: additionalStackView.trailingAnchor)

        NSLayoutConstraint.activate([containerTop, containerLeading, self.containerTrailing, self.containerToAdditionalVertical, additionalBottom, additionalTrailing, self.handleLeading])

        self.stackView = stackView
        self.containerTop = containerTop
        self.containerLeading = containerLeading
        self.additionalTrailing = additionalTrailing
        self.additionalBottom = additionalBottom
        self.additionalStackView = additionalStackView
    }
}

extension AnnotationToolbarViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        self.lastGestureRecognizerTouch = touch
        return true
    }
}

#endif
