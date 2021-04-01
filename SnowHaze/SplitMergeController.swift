//
//  SplitMergeController.swift
//  iostest
//
//
//  Copyright © 2017 Illotros GmbH. All rights reserved.
//

import Foundation
import UIKit

extension UIViewController {
/**
 *	The SplitMergeController currently presentling self.
 */
	var splitMergeController: SplitMergeController? {
		if let smc =  parent as? SplitMergeController {
			if smc.masterViewController == self || smc.detailViewController == self {
				return smc
			}
		} else if let nvc = navigationController {
			if let index = nvc.viewControllers.lastIndex(of: self), index > 0 {
				let previous = nvc.viewControllers[index - 1]
				if let smc = previous as? SplitMergeController {
					if smc.detailViewController == self {
						return smc
					}
				}
			}
		}
		return nil
	}
}

/**
 *	UIViewController that handles a master-detail relationship in both constrained and regular width scenario.
 *	Has to be the topViewController on a UINavigationController to perform as intended.
 */
class SplitMergeController: UIViewController {
/**
 *	Equivalent to the UISplitViewController.viewControllers().first()!
 *	Has to be set before view is loaded
 */
	var masterViewController: UIViewController! {
		willSet {
			masterViewController?.willMove(toParent: nil)
			masterViewController?.view.removeFromSuperview()
			masterViewController?.removeFromParent()
		}
		didSet {
			addChild(masterViewController)
			viewIfLoaded?.addSubview(masterViewController.view)
			masterViewController.didMove(toParent: self)
			use(masterViewController.navigationItem)
			if let _ = viewIfLoaded {
				layout()
			}
		}
	}

/**
 *	Equivalent to the UISplitViewController.viewControllers()[1]
 *	Setting it automaticaly pushes is on the navigationController if in constrained width mode.
 */
	var detailViewController: UIViewController? {
		willSet {
			detailFocus = false
			use(masterViewController.navigationItem)
			navigationItem.rightBarButtonItem = nil
			if constrainedWidth {
				if let _ = viewIfLoaded , navigationController!.topViewController == detailViewController {
					navigationController!.popToViewController(self, animated: true)
				}
			} else {
				detailViewController?.willMove(toParent: nil)
				detailViewController?.view.removeFromSuperview()
				detailViewController?.removeFromParent()
			}
		}
		didSet {
			if let detailViewController = detailViewController {
				if constrainedWidth {
					if let _ = viewIfLoaded {
						navigationController!.pushViewController(detailViewController, animated: true)
					}
				} else {
					use(detailViewController.navigationItem)
					addChild(detailViewController)
					viewIfLoaded?.addSubview(detailViewController.view)
					detailViewController.didMove(toParent: self)
					if let _ = viewIfLoaded {
						layout()
					}
				}
				detailFocus = true
			}
		}
	}

	var detailRightBarButtonItem: UIBarButtonItem? {
		didSet {
			if let _ = detailViewController, !constrainedWidth {
				navigationItem.setRightBarButton(detailRightBarButtonItem, animated: true)
			}
		}
	}

	private let backgroundImageView = UIImageView(image: nil)
	private var constrainedWidth = false
	private var detailFocus = false

/**
 *	Image displayed behind detailViewController.
 *	Therefore also serves as a placeholder image if detailViewController is not set.
 */
	var backgroundImage: UIImage? {
		set {
			backgroundImageView.image = newValue
			backgroundImageView.contentMode = .scaleAspectFill
		}
		get {
			return backgroundImageView.image
		}
	}

/**
 *	maps directly to view.backgroundColor
 *	cannot be accessed before view is loaded
 */
	var backgroundColor: UIColor? {
		set {
			viewIfLoaded?.backgroundColor = newValue
			navigationController?.view?.backgroundColor = newValue
		}
		get {
			return viewIfLoaded?.backgroundColor
		}
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		view.addSubview(backgroundImageView)
		constrainedWidth = traitCollection.horizontalSizeClass == .compact
		view.addSubview(masterViewController.view)
		detailFocus = false
		if let detailViewController = detailViewController , !constrainedWidth {
			view.addSubview(detailViewController.view)
		}
		layout()
		use(masterViewController.navigationItem)
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		DispatchQueue.main.async {
			self.layout()
		}
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		if constrainedWidth {
			detailFocus = false
		}
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
	}

	private func layout(for targetSize: CGSize? = nil) {
		let size = targetSize ?? view.bounds.size
		if constrainedWidth {
			masterViewController.view.frame = CGRect(origin: CGPoint.zero, size: size)
			navigationItem.setRightBarButton(nil, animated: true)
		} else {
			let masterWidth = (size.width - 200) * 0.3 + 200
			let detailWidth = size.width - masterWidth
			let masterFrame = CGRect(x: 0, y: 0, width: masterWidth, height: size.height)
			let detailFrame = CGRect(x: masterWidth, y: 0, width: detailWidth, height: size.height)
			masterViewController.view.frame = masterFrame
			backgroundImageView.frame = detailFrame
			detailViewController?.view.frame = detailFrame
			navigationItem.setRightBarButton(detailRightBarButtonItem, animated: true)
		}
	}

	private func use(_ navItem: UINavigationItem) {
		navigationItem.title = navItem.title
		navigationItem.titleView = navItem.titleView
		navigationItem.prompt = navItem.prompt
		navigationItem.backButtonTitle = navItem.backButtonTitle
		if #available(iOS 14, *) {
			navigationItem.backButtonDisplayMode = navItem.backButtonDisplayMode
		}
	}
}

//UIContentContainer methods
extension SplitMergeController {
	override func willTransition(to newCollection: UITraitCollection, with coordinator: UIViewControllerTransitionCoordinator) {
		super.willTransition(to: newCollection, with: coordinator)
		let oldConstrainedWidth = constrainedWidth
		constrainedWidth = newCollection.horizontalSizeClass == .compact
		if !oldConstrainedWidth && constrainedWidth {
			use(masterViewController.navigationItem)
			if let detailViewController = detailViewController {
				detailViewController.willMove(toParent: nil)
				detailViewController.view.removeFromSuperview()
				detailViewController.removeFromParent()
				if detailFocus {
					navigationController!.pushViewController(detailViewController, animated: false)
				}
			}
		} else if !constrainedWidth && oldConstrainedWidth {
			if let detailViewController = detailViewController {
				use(detailViewController.navigationItem)
				if navigationController!.topViewController == detailViewController {
					navigationController!.popToViewController(self, animated: false)
				}
				addChild(detailViewController)
				viewIfLoaded?.addSubview(detailViewController.view)
				detailViewController.didMove(toParent: self)
			}
		}
	}

	override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
		super.viewWillTransition(to: size, with: coordinator)
		//Wait for view.bounds to be adjusted to the new size
		coordinator.animate(alongsideTransition: { _ in
			self.layout(for: size)
		})
	}
}
