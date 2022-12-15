//
//  PDFDocumentViewController.swift
//  Zotero
//
//  Created by Michal Rentka on 24/04/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

#if PDFENABLED

import UIKit

import CocoaLumberjackSwift
import PSPDFKit
import PSPDFKitUI
import RxSwift
import RealmSwift

protocol PDFDocumentDelegate: AnyObject {
    func annotationTool(didChangeStateFrom oldState: PSPDFKit.Annotation.Tool?, to newState: PSPDFKit.Annotation.Tool?,
                        variantFrom oldVariant: PSPDFKit.Annotation.Variant?, to newVariant: PSPDFKit.Annotation.Variant?)
    func didChange(undoState undoEnabled: Bool, redoState redoEnabled: Bool)
    func interfaceVisibilityDidChange(to isHidden: Bool)
}

final class PDFDocumentViewController: UIViewController {
    private(set) weak var pdfController: PDFViewController!

    private let viewModel: ViewModel<PDFReaderActionHandler>
    private let disposeBag: DisposeBag

    private var annotationTimerDisposeBag: DisposeBag
    private var pageTimerDisposeBag: DisposeBag
    private var selectionView: SelectionView?
    private var didAppear: Bool
    var scrubberBarHeight: CGFloat {
        return self.pdfController.userInterfaceView.scrubberBar.frame.height
    }

    weak var parentDelegate: (PDFReaderContainerDelegate & PDFDocumentDelegate)?
    weak var coordinatorDelegate: (DetailPdfCoordinatorDelegate)?

    // MARK: - Lifecycle

    init(viewModel: ViewModel<PDFReaderActionHandler>, compactSize: Bool) {
        self.viewModel = viewModel
        self.didAppear = false
        self.disposeBag = DisposeBag()
        self.annotationTimerDisposeBag = DisposeBag()
        self.pageTimerDisposeBag = DisposeBag()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        self.view.backgroundColor = .systemGray6
        self.setupViews()
        self.set(toolColor: self.viewModel.state.activeColor, in: self.pdfController.annotationStateManager)
        self.setupObserving()
        self.updateInterface(to: self.viewModel.state.settings)

        self.pdfController.setPageIndex(PageIndex(self.viewModel.state.visiblePage), animated: false)
        self.select(annotation: self.viewModel.state.selectedAnnotation, pageIndex: self.pdfController.pageIndex, document: self.viewModel.state.document)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.didAppear = true
    }

    deinit {
        self.pdfController?.annotationStateManager.remove(self)
        DDLogInfo("PDFDocumentViewController deinitialized")
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        guard self.viewIfLoaded != nil else { return }

        coordinator.animate(alongsideTransition: { _ in
            // Update highlight selection if needed
            if let annotation = self.viewModel.state.selectedAnnotation,
               let pageView = self.pdfController.pageViewForPage(at: self.pdfController.pageIndex) {
                self.updateSelection(on: pageView, annotation: annotation)
            }
        }, completion: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        guard !self.didAppear else { return }

        if let (page, _) = self.viewModel.state.focusDocumentLocation, let annotation = self.viewModel.state.selectedAnnotation {
            self.select(annotation: annotation, pageIndex: PageIndex(page), document: self.viewModel.state.document)
        }
    }

    // MARK: - Actions

    func focus(page: UInt) {
        self.scrollIfNeeded(to: page, animated: true, completion: {})
    }

    func highlight(result: SearchResult) {
        self.pdfController.searchHighlightViewManager.clearHighlightedSearchResults(animated: (self.pdfController.pageIndex == result.pageIndex))
        self.scrollIfNeeded(to: result.pageIndex, animated: true) {
            self.pdfController.searchHighlightViewManager.addHighlight([result], animated: true)
        }
    }

    func toggle(annotationTool: PSPDFKit.Annotation.Tool, tappedWithStylus: Bool, resetPencilManager: Bool = true) {
        let stateManager = self.pdfController.annotationStateManager
        stateManager.stylusMode = .fromStylusManager

        if stateManager.state == annotationTool {
            stateManager.setState(nil, variant: nil)
            if resetPencilManager {
                PSPDFKit.SDK.shared.applePencilManager.detected = false
                PSPDFKit.SDK.shared.applePencilManager.enabled = false
            }
            return
        } else if tappedWithStylus {
            PSPDFKit.SDK.shared.applePencilManager.detected = true
            PSPDFKit.SDK.shared.applePencilManager.enabled = true
        }

        stateManager.setState(annotationTool, variant: nil)

        let (color, _, blendMode) = AnnotationColorGenerator.color(from: self.viewModel.state.activeColor, isHighlight: (annotationTool == .highlight), userInterfaceStyle: self.traitCollection.userInterfaceStyle)
        stateManager.drawColor = color
        stateManager.blendMode = blendMode ?? .normal

        switch annotationTool {
        case .ink:
            stateManager.lineWidth = self.viewModel.state.activeLineWidth
            if UIPencilInteraction.prefersPencilOnlyDrawing {
                stateManager.stylusMode = .stylus
            }

        case .eraser:
            stateManager.lineWidth = self.viewModel.state.activeEraserSize

        default: break
        }
    }

    private func update(state: PDFReaderState) {
        if state.changes.contains(.interfaceStyle) {
            self.updateInterface(to: state.settings)
        }

        if state.changes.contains(.settings) {
            self.updateInterface(to: state.settings)

            if self.pdfController.configuration.scrollDirection != state.settings.direction ||
               self.pdfController.configuration.pageTransition != state.settings.transition ||
               self.pdfController.configuration.pageMode != state.settings.pageMode ||
               self.pdfController.configuration.spreadFitting != state.settings.pageFitting {
                self.pdfController.updateConfiguration { configuration in
                    configuration.scrollDirection = state.settings.direction
                    configuration.pageTransition = state.settings.transition
                    configuration.pageMode = state.settings.pageMode
                    configuration.spreadFitting = state.settings.pageFitting
                }
            }
        }

        if state.changes.contains(.selection) {
            if let annotation = state.selectedAnnotation {
                if let location = state.focusDocumentLocation {
                    // If annotation was selected, focus if needed
                    self.focus(annotation: annotation, at: location, document: state.document)
                } else if annotation.type != .ink || self.pdfController.annotationStateManager.state != .ink {
                    // Update selection if needed.
                    // Never select ink annotation if inking is active in case the user needs to continue typing.
                    self.select(annotation: annotation, pageIndex: self.pdfController.pageIndex, document: state.document)
                }
            } else {
                // Otherwise remove selection if needed
                self.select(annotation: nil, pageIndex: self.pdfController.pageIndex, document: state.document)
            }

            self.showPopupAnnotationIfNeeded(state: state)
        }

        if state.changes.contains(.activeColor) {
            self.set(toolColor: state.activeColor, in: self.pdfController.annotationStateManager)
        }

        if state.changes.contains(.activeLineWidth) {
            self.set(lineWidth: state.activeLineWidth, in: self.pdfController.annotationStateManager)
        }

        if state.changes.contains(.activeEraserSize) {
            self.set(lineWidth: state.activeEraserSize, in: self.pdfController.annotationStateManager)
        }

        if let error = state.error {
            // TODO: - show error
        }

        if let notification = state.pdfNotification {
            self.updatePdf(notification: notification)
        }
    }

    private func updatePdf(notification: Notification) {
        switch notification.name {
        case .PSPDFAnnotationChanged:
            guard let changes = notification.userInfo?[PSPDFAnnotationChangedNotificationKeyPathKey] as? [String] else { return }
            // Changing annotation color changes the `lastUsed` color in `annotationStateManager` (#487), so we have to re-set it.
            if changes.contains("color") {
                self.set(toolColor: self.viewModel.state.activeColor, in: self.pdfController.annotationStateManager)
            }

        case .PSPDFAnnotationsAdded:
            guard let annotations = notification.object as? [PSPDFKit.Annotation] else { return }
            // If Image annotation is active after adding the annotation, deactivate it
            if annotations.first is PSPDFKit.SquareAnnotation && self.pdfController.annotationStateManager.state == .square {
                // Don't reset apple pencil detection here, this is automatic action, not performed by user.
                self.toggle(annotationTool: .square, tappedWithStylus: false, resetPencilManager: false)
            }

        default: break
        }
    }

    private func updateInterface(to settings: PDFSettings) {
        switch settings.appearanceMode {
        case .automatic:
            self.pdfController.appearanceModeManager.appearanceMode = self.traitCollection.userInterfaceStyle == .dark ? .night : []
        case .light:
            self.pdfController.appearanceModeManager.appearanceMode = []
        case .dark:
            self.pdfController.appearanceModeManager.appearanceMode = .night
        }
    }

    private func showPopupAnnotationIfNeeded(state: PDFReaderState) {
        guard !(self.parentDelegate?.isSidebarVisible ?? false),
              let annotation = state.selectedAnnotation,
              let pageView = self.pdfController.pageViewForPage(at: UInt(annotation.page)) else { return }

        let frame = self.view.convert(annotation.boundingBox(boundingBoxConverter: self), from: pageView.pdfCoordinateSpace)

        self.coordinatorDelegate?.showAnnotationPopover(viewModel: self.viewModel, sourceRect: frame, popoverDelegate: self)
    }

    private func updatePencilSettingsIfNeeded() {
        guard self.pdfController.annotationStateManager.state == .ink else { return }
        self.pdfController.annotationStateManager.stylusMode = UIPencilInteraction.prefersPencilOnlyDrawing ? .stylus : .fromStylusManager
    }

    /// Scrolls to given page if needed.
    /// - parameter pageIndex: Page index to which the `pdfController` is supposed to scroll.
    /// - parameter animated: `true` if scrolling is animated, `false` otherwise.
    /// - parameter completion: Completion block called after scroll. Block is also called when scroll was not needed.
    private func scrollIfNeeded(to pageIndex: PageIndex, animated: Bool, completion: @escaping () -> Void) {
        guard self.pdfController.pageIndex != pageIndex else {
            completion()
            return
        }

        if !animated {
            self.pdfController.setPageIndex(pageIndex, animated: false)
            completion()
            return
        }

        UIView.animate(withDuration: 0.25, animations: {
            self.pdfController.setPageIndex(pageIndex, animated: false)
        }, completion: { finished in
            guard finished else { return }
            completion()
        })
    }

    private func set(toolColor: UIColor, in stateManager: AnnotationStateManager) {
        let highlightColor = AnnotationColorGenerator.color(from: toolColor, isHighlight: true,
                                                            userInterfaceStyle: self.traitCollection.userInterfaceStyle).color

        stateManager.setLastUsedColor(highlightColor, annotationString: .highlight)
        stateManager.setLastUsedColor(toolColor, annotationString: .note)
        stateManager.setLastUsedColor(toolColor, annotationString: .square)

        if stateManager.state == .highlight {
            stateManager.drawColor = highlightColor
        } else {
            stateManager.drawColor = toolColor
        }
    }

    private func set(lineWidth: CGFloat, in stateManager: AnnotationStateManager) {
        stateManager.lineWidth = lineWidth
    }

    // MARK: - Selection

    /// (De)Selects given annotation in document.
    /// - parameter annotation: Annotation to select. Existing selection will be deselected if set to `nil`.
    /// - parameter pageIndex: Page index of page where (de)selection should happen.
    /// - parameter document: Active `Document` instance.
    private func select(annotation: Annotation?, pageIndex: PageIndex, document: PSPDFKit.Document) {
        guard let pageView = self.pdfController.pageViewForPage(at: pageIndex) else { return }

        self.updateSelection(on: pageView, annotation: annotation)

        if let annotation = annotation, let pdfAnnotation = document.annotation(on: Int(pageIndex), with: annotation.key) {
            if !pageView.selectedAnnotations.contains(pdfAnnotation) {
                pageView.selectedAnnotations = [pdfAnnotation]
            }
        } else {
            if !pageView.selectedAnnotations.isEmpty {
                pageView.selectedAnnotations = []
            }
        }
    }

    /// Focuses given annotation and selects it if it's not selected yet.
    private func focus(annotation: Annotation, at location: AnnotationDocumentLocation, document: PSPDFKit.Document) {
        let pageIndex = PageIndex(location.page)
        self.scrollIfNeeded(to: pageIndex, animated: true) {
            self.select(annotation: annotation, pageIndex: pageIndex, document: document)
        }
    }

    /// Updates `SelectionView` for `PDFPageView` based on selected annotation.
    /// - parameter pageView: `PDFPageView` instance for given page.
    /// - parameter selectedAnnotation: Selected annotation or `nil` if there is no selection.
    private func updateSelection(on pageView: PDFPageView, annotation: Annotation?) {
        // Delete existing custom highlight selection view
        if let view = self.selectionView {
            view.removeFromSuperview()
        }

        guard let selection = annotation, selection.type == .highlight && selection.page == Int(pageView.pageIndex) else { return }
        // Add custom highlight selection view if needed
        let frame = pageView.convert(selection.boundingBox(boundingBoxConverter: self), from: pageView.pdfCoordinateSpace).insetBy(dx: -SelectionView.inset, dy: -SelectionView.inset)
        let selectionView = SelectionView()
        selectionView.frame = frame
        pageView.annotationContainerView.addSubview(selectionView)
        self.selectionView = selectionView
    }

    // MARK: - Setups

    private func setupViews() {
        let pdfController = self.createPdfController(with: self.viewModel.state.document, settings: self.viewModel.state.settings)
        pdfController.view.translatesAutoresizingMaskIntoConstraints = false

        pdfController.willMove(toParent: self)
        self.addChild(pdfController)
        self.view.addSubview(pdfController.view)
        pdfController.didMove(toParent: self)

        NSLayoutConstraint.activate([
            pdfController.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            pdfController.view.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor),
            pdfController.view.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor),
            pdfController.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor)
        ])

        self.pdfController = pdfController
    }

    private func createPdfController(with document: PSPDFKit.Document, settings: PDFSettings) -> PDFViewController {
        let pdfConfiguration = PDFConfiguration { builder in
            builder.scrollDirection = settings.direction
            builder.pageTransition = settings.transition
            builder.pageMode = settings.pageMode
            builder.spreadFitting = settings.pageFitting
            builder.documentLabelEnabled = .NO
            builder.allowedAppearanceModes = [.night]
            builder.isCreateAnnotationMenuEnabled = true
            builder.createAnnotationMenuGroups = self.createAnnotationCreationMenuGroups()
            builder.allowedMenuActions = [.copy, .search, .speak, .share, .annotationCreation, .define]
            builder.scrubberBarType = .horizontal
//            builder.thumbnailBarMode = .scrubberBar
            builder.markupAnnotationMergeBehavior = .never
            builder.overrideClass(PSPDFKit.HighlightAnnotation.self, with: HighlightAnnotation.self)
            builder.overrideClass(PSPDFKit.NoteAnnotation.self, with: NoteAnnotation.self)
            builder.overrideClass(PSPDFKit.SquareAnnotation.self, with: SquareAnnotation.self)
        }

        let controller = PDFViewController(document: document, configuration: pdfConfiguration)
        controller.view.backgroundColor = .systemGray6
        controller.delegate = self
        controller.formSubmissionDelegate = nil
        controller.annotationStateManager.add(self)
        controller.annotationStateManager.pencilInteraction.delegate = self
        self.setup(scrubberBar: controller.userInterfaceView.scrubberBar)
        self.setup(interactions: controller.interactions)

        return controller
    }

    private func createAnnotationCreationMenuGroups() -> [AnnotationToolConfiguration.ToolGroup] {
        return [AnnotationToolConfiguration.ToolGroup(items: [
                AnnotationToolConfiguration.ToolItem(type: .highlight),
                AnnotationToolConfiguration.ToolItem(type: .note),
                AnnotationToolConfiguration.ToolItem(type: .square),
                AnnotationToolConfiguration.ToolItem(type: .ink, variant: .inkPen)
        ])]
    }

    private func setup(scrubberBar: ScrubberBar) {
        let appearance = UIToolbarAppearance()
        appearance.backgroundColor = Asset.Colors.pdfScrubberBarBackground.color

        scrubberBar.standardAppearance = appearance
        scrubberBar.compactAppearance = appearance
    }

    private func setup(interactions: DocumentViewInteractions) {
        // Only supported annotations can be selected
        interactions.selectAnnotation.addActivationCondition { context, _, _ -> Bool in
            return AnnotationsConfig.supported.contains(context.annotation.type)
        }
        
        interactions.selectAnnotation.addActivationCallback { [weak self] context, _, _ in
            let key = context.annotation.key ?? context.annotation.uuid
            let type: PDFReaderState.AnnotationKey.Kind = context.annotation.isZoteroAnnotation ? .database : .document
            self?.viewModel.process(action: .selectAnnotationFromDocument(PDFReaderState.AnnotationKey(key: key, type: type)))
        }
        
        interactions.toggleUserInterface.addActivationCallback { [weak self] _, _, _ in
            guard let interfaceView = self?.pdfController.userInterfaceView else { return }
            self?.parentDelegate?.interfaceVisibilityDidChange(to: interfaceView.alpha != 0)
        }

        interactions.deselectAnnotation.addActivationCondition { [weak self] _, _, _ -> Bool in
            // `interactions.deselectAnnotation.addActivationCallback` is not always called when highglight annotation tool is enabled.
            self?.viewModel.process(action: .deselectSelectedAnnotation)
            return true
        }

        // Only Zotero-synced annotations can be edited
        interactions.editAnnotation.addActivationCondition { context, _, _ -> Bool in
            return context.annotation.key != nil && context.annotation.isEditable
        }
    }

    private func setupObserving() {
        self.viewModel.stateObservable
                      .observe(on: MainScheduler.instance)
                      .subscribe(onNext: { [weak self] state in
                          self?.update(state: state)
                      })
                      .disposed(by: self.disposeBag)

        NotificationCenter.default.rx
                                  .notification(UIApplication.didBecomeActiveNotification)
                                  .observe(on: MainScheduler.instance)
                                  .subscribe(onNext: { [weak self] notification in
                                      guard let `self` = self else { return }
                                      self.viewModel.process(action: .updateAnnotationPreviews)
                                      self.updatePencilSettingsIfNeeded()
                                  })
                                  .disposed(by: self.disposeBag)
    }
}

extension PDFDocumentViewController: PDFViewControllerDelegate {
    func pdfViewController(_ pdfController: PDFViewController, willBeginDisplaying pageView: PDFPageView, forPageAt pageIndex: Int) {
        // This delegate method is called for incorrect page index when sidebar is changing size. So if the sidebar is opened/closed, incorrect page
        // is stored in `pageController` and if the user closes the pdf reader without further scrolling, incorrect page is shown on next opening.
        guard !(self.parentDelegate?.isSidebarTransitioning ?? false) else { return }
        // Save current page
        self.viewModel.process(action: .setVisiblePage(pageIndex))
    }

    func pdfViewController(_ pdfController: PDFViewController, shouldShow controller: UIViewController, options: [String : Any]? = nil, animated: Bool) -> Bool {
        return false
    }

    func pdfViewController(_ pdfController: PDFViewController, shouldShow menuItems: [MenuItem], atSuggestedTargetRect rect: CGRect, for annotations: [PSPDFKit.Annotation]?, in annotationRect: CGRect,
                           on pageView: PDFPageView) -> [MenuItem] {
        guard annotations == nil && self.viewModel.state.library.metadataEditable else { return [] }

        let pageRect = pageView.convert(rect, to: pageView.pdfCoordinateSpace)

        return [MenuItem(title: "Note", block: { [weak self] in
                    self?.viewModel.process(action: .create(annotation: .note, pageIndex: pageView.pageIndex, origin: pageRect.origin))
                }),
                MenuItem(title: "Image", block: { [weak self] in
                    self?.viewModel.process(action: .create(annotation: .image, pageIndex: pageView.pageIndex, origin: pageRect.origin))
                })]
    }

    func pdfViewController(_ pdfController: PDFViewController, shouldShow menuItems: [MenuItem], atSuggestedTargetRect rect: CGRect,
                           forSelectedText selectedText: String, in textRect: CGRect, on pageView: PDFPageView) -> [MenuItem] {
        let identifiers: [String]
        if self.viewModel.state.library.metadataEditable {
            identifiers = [TextMenu.copy.rawValue, TextMenu.annotationMenuHighlight.rawValue, TextMenu.define.rawValue, TextMenu.search.rawValue, TextMenu.speak.rawValue, TextMenu.share.rawValue]
        } else {
            identifiers = [TextMenu.copy.rawValue, TextMenu.define.rawValue, TextMenu.search.rawValue, TextMenu.speak.rawValue, TextMenu.share.rawValue]
        }

        // Filter unwanted items
        let filtered = menuItems.filter({ item in
            guard let identifier = item.identifier else { return false }
            return identifiers.contains(identifier)
        })

        // Overwrite highlight title
        if let idx = filtered.firstIndex(where: { $0.identifier == TextMenu.annotationMenuHighlight.rawValue }) {
            filtered[idx].title = L10n.Pdf.highlight
        }

        // Overwrite share action, because the original one reports "[ShareSheet] connection invalidated".
        if let idx = filtered.firstIndex(where: { $0.identifier == TextMenu.share.rawValue }) {
            filtered[idx].actionBlock = { [weak self] in
                guard let view = self?.pdfController.view else { return }
                self?.coordinatorDelegate?.share(text: selectedText, rect: rect, view: view)
            }
        }

        // Overwrite define action, because the original one doesn't show anything.
        if let idx = filtered.firstIndex(where: { $0.identifier == TextMenu.define.rawValue }) {
            filtered[idx].title = L10n.lookUp
            filtered[idx].actionBlock = { [weak self] in
                guard let view = self?.pdfController.view else { return }
                self?.coordinatorDelegate?.lookup(text: selectedText, rect: rect, view: view)
            }
        }

        if let idx = filtered.firstIndex(where: { $0.identifier == TextMenu.search.rawValue }) {
            filtered[idx].actionBlock = { [weak self] in
                guard let `self` = self else { return }
                self.parentDelegate?.showSearch(pdfController: self.pdfController, text: selectedText)
            }
        }

        return filtered
    }

    func pdfViewController(_ pdfController: PDFViewController, shouldSave document: PSPDFKit.Document, withOptions options: AutoreleasingUnsafeMutablePointer<NSDictionary>) -> Bool {
        return false
    }
}

extension PDFDocumentViewController: AnnotationStateManagerDelegate {
    func annotationStateManager(_ manager: AnnotationStateManager,
                                didChangeState oldState: PSPDFKit.Annotation.Tool?,
                                to newState: PSPDFKit.Annotation.Tool?,
                                variant oldVariant: PSPDFKit.Annotation.Variant?,
                                to newVariant: PSPDFKit.Annotation.Variant?) {
        self.parentDelegate?.annotationTool(didChangeStateFrom: oldState, to: newState, variantFrom: oldVariant, to: newVariant)
    }

    func annotationStateManager(_ manager: AnnotationStateManager, didChangeUndoState undoEnabled: Bool, redoState redoEnabled: Bool) {
        self.parentDelegate?.didChange(undoState: undoEnabled, redoState: redoEnabled)
    }
}

extension PDFDocumentViewController: UIPencilInteractionDelegate {
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        // TODO: !!!
        switch UIPencilInteraction.preferredTapAction {
        case .switchEraser:
            break

        case .showColorPalette: break

        case .switchPrevious, .showInkAttributes, .ignore: break

        @unknown default: break
        }
    }
}

extension PDFDocumentViewController: UIPopoverPresentationControllerDelegate {
    func popoverPresentationControllerDidDismissPopover(_ popoverPresentationController: UIPopoverPresentationController) {
        if self.viewModel.state.selectedAnnotation?.type == .highlight {
            self.viewModel.process(action: .deselectSelectedAnnotation)
        }
    }
}

extension PDFDocumentViewController: AnnotationBoundingBoxConverter {
    /// Converts from database to PSPDFKit rect. Database stores rects in RAW PDF Coordinate space. PSPDFKit works with Normalized PDF Coordinate Space.
    func convertFromDb(rect: CGRect, page: PageIndex) -> CGRect? {
        guard let pageInfo = self.viewModel.state.document.pageInfoForPage(at: page) else { return nil }
        return rect.applying(pageInfo.transform)
    }

    func convertFromDb(point: CGPoint, page: PageIndex) -> CGPoint? {
        let tmpRect = CGRect(origin: point, size: CGSize(width: 1, height: 1))
        return self.convertFromDb(rect: tmpRect, page: page)?.origin
    }

    /// Converts from PSPDFKit to database rect. Database stores rects in RAW PDF Coordinate space. PSPDFKit works with Normalized PDF Coordinate Space.
    func convertToDb(rect: CGRect, page: PageIndex) -> CGRect? {
        guard let pageInfo = self.viewModel.state.document.pageInfoForPage(at: page) else { return nil }
        return rect.applying(pageInfo.transform.inverted())
    }

    func convertToDb(point: CGPoint, page: PageIndex) -> CGPoint? {
        let tmpRect = CGRect(origin: point, size: CGSize(width: 1, height: 1))
        return self.convertToDb(rect: tmpRect, page: page)?.origin
    }

    /// Converts from PSPDFKit to sort index rect. PSPDFKit works with Normalized PDF Coordinate Space. Sort index stores y coordinate in RAW View Coordinate Space.
    func sortIndexMinY(rect: CGRect, page: PageIndex) -> CGFloat? {
        guard let pageInfo = self.viewModel.state.document.pageInfoForPage(at: page) else { return nil }

        switch pageInfo.savedRotation {
        case .rotation0:
            return pageInfo.size.height - rect.maxY
        case .rotation180:
            return rect.minY
        case .rotation90:
            return pageInfo.size.width - rect.minX
        case .rotation270:
            return rect.minX
        }
    }

    func textOffset(rect: CGRect, page: PageIndex) -> Int? {
        guard let parser = self.viewModel.state.document.textParserForPage(at: page), !parser.glyphs.isEmpty else { return nil }

        var index = 0
        var minDistance: CGFloat = .greatestFiniteMagnitude
        var textOffset = 0

        for glyph in parser.glyphs {
            guard !glyph.isWordOrLineBreaker else { continue }

            let distance = rect.distance(to: glyph.frame)

            if distance < minDistance {
                minDistance = distance
                textOffset = index
            }

            index += 1
        }

        return textOffset
    }
}

final class SelectionView: UIView {
    static let inset: CGFloat = 4.5 // 2.5 for border, 2 for padding

    init() {
        super.init(frame: CGRect())
        self.commonSetup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.commonSetup()
    }

    private func commonSetup() {
        self.backgroundColor = .clear
        self.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin, .flexibleBottomMargin, .flexibleRightMargin, .flexibleWidth, .flexibleHeight]
        self.layer.borderColor = Asset.Colors.annotationHighlightSelection.color.cgColor
        self.layer.borderWidth = 2.5
        self.layer.cornerRadius = 2.5
        self.layer.masksToBounds = true
    }
}

#endif
