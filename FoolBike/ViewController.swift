//
//  ViewController.swift
//  LocationTest
//
//  Created by Björn Oelke on 10.08.15.
//  Copyright (c) 2015 Björn Oelke. All rights reserved.
//

import UIKit
import CoreLocation
import MapKit
import HealthKit

class ViewController: UIViewController, CLLocationManagerDelegate, MKMapViewDelegate {

	@IBOutlet var mv:MKMapView!
	@IBOutlet var tv:UITextView!
	
	@IBOutlet var btn:UIButton!
	
	@IBOutlet var timeLabel:UILabel!
	@IBOutlet var distLabel:UILabel!
	
	var hs:HKHealthStore! = HKHealthStore()
	
	var lm:CLLocationManager! = CLLocationManager()
	var started = false
	
	var locs:[CLLocation]! = []
	var line:MKPolyline?
	
	var time:NSTimeInterval! = 0
	var dist:CLLocationDistance! = 0
	
	var changes = 0
	var notmoving = false
	
	override func viewDidLoad() {
		super.viewDidLoad()
		
		let lstatus = CLLocationManager.authorizationStatus()

		lm.desiredAccuracy = kCLLocationAccuracyBest
		lm.activityType = CLActivityType.Fitness
		lm.delegate = self
		
		if lstatus == CLAuthorizationStatus.NotDetermined {
			lm.requestAlwaysAuthorization()
			log("Requesting location access")
		} else if lstatus == CLAuthorizationStatus.Denied {
			log("You denied location access.")
		}
		
		let hstatus = hs.authorizationStatusForType(HKObjectType.workoutType())
		if hstatus != HKAuthorizationStatus.SharingAuthorized {
			let share:Set = [HKSampleType.workoutType()]
			let read:Set = [HKObjectType.quantityTypeForIdentifier(HKQuantityTypeIdentifierBodyMass)]
			hs.requestAuthorizationToShareTypes(share, readTypes: read, completion: {(ok, err) in
				if err != nil {
					println(String(format: "req error: %@", err))
					return
				}
				println(String(format: "ok: %@", ok ? "true" : "false"))
			})
		}
	}

	override func didReceiveMemoryWarning() {
		super.didReceiveMemoryWarning()
	}

	@IBAction func trigger() {
		if started {
			stop()
		} else {
			start()
		}
	}
	
	@IBAction func changeMapType(seg: UISegmentedControl!) {
		var type:MKMapType = MKMapType.Standard
		if seg.selectedSegmentIndex == 1 {
			type = MKMapType.Hybrid
		} else if seg.selectedSegmentIndex == 2 {
			type = MKMapType.Satellite
		}
		mv.mapType = type
	}
	
	func log(text: String!) {
		tv.text = text + "\n" + tv.text
		println(NSDate().description + ": " + text)
	}
	
	func update() {
		var df = NSDateComponentsFormatter()
		df.unitsStyle = NSDateComponentsFormatterUnitsStyle.Positional
		df.allowedUnits = NSCalendarUnit.CalendarUnitHour | NSCalendarUnit.CalendarUnitMinute | NSCalendarUnit.CalendarUnitSecond
		df.zeroFormattingBehavior = NSDateComponentsFormatterZeroFormattingBehavior.Pad
		timeLabel.text = df.stringFromTimeInterval(time)
		distLabel.text = String(format: "%.2f km", dist / 1000.0)
		
		centerMap()
		updateLine()
	}
	
	func updateLine() {
		if locs.count < 2 {
			return
		}
		
		var cs:[CLLocationCoordinate2D] = []
		cs.reserveCapacity(locs.count)
		for loc in locs {
			cs.append(loc.coordinate)
		}
		let pl = MKPolyline(coordinates: &cs, count: cs.count)

		let old = line
		line = pl
		
		if old != nil {
			mv.removeOverlay(old)
		}
		mv.addOverlay(pl)
	}
	
	func centerMap() {
		var coordinate = lm.location.coordinate
		if let last = locs.last {
			coordinate = last.coordinate
		}
		
		let region = mv.regionThatFits(MKCoordinateRegionMake(
			coordinate,
			MKCoordinateSpanMake(0.005, 0.0)
			))
		mv.setRegion(region, animated: true)
		
	}
	
	func reset() {
		locs = []
		time = 0
		dist = 0
		changes = 0
	}
	
	func stop() {
		lm.stopUpdatingLocation()
		started = false

		var df = NSDateComponentsFormatter()
		df.unitsStyle = NSDateComponentsFormatterUnitsStyle.Positional
		df.allowedUnits = NSCalendarUnit.CalendarUnitHour | NSCalendarUnit.CalendarUnitMinute | NSCalendarUnit.CalendarUnitSecond
		df.zeroFormattingBehavior = NSDateComponentsFormatterZeroFormattingBehavior.Pad

		log("Stop!");
		log(String(format: "distance: %.2f km, time: %@", dist / 1000.0, df.stringFromTimeInterval(time)!))
		log("=======");

		btn.setTitle("Start", forState: UIControlState.Normal)

		if time < 60.0 {
			// ignore 1 minute rides
			return
		}
		
		saveWorkout()
	}
	
	func saveWorkout() {
		// check authorization
		let hstatus = hs.authorizationStatusForType(HKObjectType.workoutType())
		if hstatus != HKAuthorizationStatus.SharingAuthorized {
			return;
		}

		// weight * mph * 0.4 * hrs
		// kmh * 0.6 = mph
		let saveWithWeight:(Double -> Void) = {(weight) in
			var w = weight
			if w == 0 {
				w = 75
			}
			let kmh = 3.6 * self.time * self.dist
			let cal = w * (kmh * 0.6 * 0.4) * (self.time / 60.0)
			let workout = HKWorkout(
				activityType: HKWorkoutActivityType.Cycling,
				startDate: self.locs[0].timestamp,
				endDate: self.locs.last?.timestamp,
				duration: self.time,
				totalEnergyBurned: nil,
				totalDistance: HKQuantity(unit: HKUnit.meterUnit(), doubleValue: self.dist),
				metadata: nil
			)
			self.log(String(format: "weight: %d", w))
			// TODO: actually save this
		}
		
		let type = HKObjectType.quantityTypeForIdentifier(HKQuantityTypeIdentifierBodyMass)
		let sort = NSSortDescriptor(key:HKSampleSortIdentifierEndDate, ascending:false)
		let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort], resultsHandler: {(query, results, err) in
			if err != nil {
				self.log(err.localizedDescription)
				return
			}
			if results == nil || results.count == 0 {
				self.log("no weight available")
				saveWithWeight(0.0)
				return
			}
			let sample = results.last as? HKQuantitySample
			let quantity = sample?.quantity
			let weight = quantity?.doubleValueForUnit(HKUnit.gramUnitWithMetricPrefix(HKMetricPrefix.Kilo))
			if weight == nil {
				self.log("could not extract weight")
				saveWithWeight(0.0)
			} else {
				saveWithWeight(weight!)
			}
		})
	}
	
	func start() {
		reset()
		
		let status = CLLocationManager.authorizationStatus()
		if status != CLAuthorizationStatus.AuthorizedWhenInUse && status != CLAuthorizationStatus.AuthorizedAlways {
			log("no permissions to start!")
			return
		}
		if started {
			return
		}
		started = true
		log("Start!")
		lm.startUpdatingLocation()

		btn.setTitle("Stop", forState: UIControlState.Normal)
	}

	/**
	 * CLLocationManagerDelegate
	 */
	func locationManager(manager: CLLocationManager!, didUpdateLocations locations: [AnyObject]!) {
		if locations.count > 1 {
			log(String(format: "%d locations recieved", locations.count))
		}

		for item in locations {
			changes++

			let loc = item as! CLLocation
			let last = locs.last
			
			var d = 0.0
			if last != nil {
				d = loc.distanceFromLocation(last)
			} else {
				// add the first
				locs.append(loc)
			}
			
			// ignore init value, small movements (probably false positives) and the first few updates (they're inacrurate)
			if last == nil || changes <= 5 {
				locs[0] = loc
				continue
			}
			if d < 1.0 {
				if !notmoving {
					log("no movement")
					notmoving = true
				}
				continue
			}
			notmoving = false

			log(String(format: "moved: %.1f meters", d))

			dist = dist + d
			time = time + loc.timestamp.timeIntervalSinceDate(last!.timestamp)
			locs.append(loc)
		}

		update()
	}
	
	func locationManager(manager: CLLocationManager!, didFailWithError error: NSError!) {
		log(error.localizedDescription)
	}
	
	/**
	 * MKMapViewDelegate
	 */
	func mapView(_: MKMapView!, rendererForOverlay overlay: MKOverlay!) -> MKOverlayRenderer! {
		let ret = MKPolylineRenderer(polyline: overlay as? MKPolyline)
		ret.strokeColor = UIColor(red: 0.3, green: 0.5, blue: 1, alpha: 0.6)
		ret.lineWidth = 5
		return ret

	}
}