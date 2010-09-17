/**
 * Copyright (C) 2009 bdferris <bdferris@onebusaway.org>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *         http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "OBASearchControllerImpl.h"
#import "OBARoute.h"
#import "OBAPlacemark.h"
#import "OBAAgencyWithCoverage.h"
#import "OBANavigationTargetAnnotation.h"
#import "OBAProgressIndicatorImpl.h"
#import "OBASphericalGeometryLibrary.h"
#import "OBAJsonDataSource.h"
#import "OBALogger.h"


static const float kSearchRadius = 400;

@interface OBASearchControllerImpl (Internal)

- (OBASearchControllerSearchType) searchTypeForNumber:(NSNumber*)number;

- (CLLocation*) currentLocationToSearch;
- (CLLocation*) currentOrDefaultLocationToSearch;

-(void) searchByCurrentLocation;
-(void) searchByLocationRegion:(MKCoordinateRegion)region;
-(void) searchByRoute:(NSString*)routeQuery;
-(void) searchByRouteStops:(NSString*)routeId;
-(void) searchByStopId:(NSString*)stopIdQuery;
-(void) searchByAddress:(NSString*)addressQuery;
-(void) searchByPlacemark:(OBAPlacemark*)placemark;
-(void) searchForAgenciesWithCoverage;

- (void) requestPath:(NSString*)path withArgs:(NSString*)args searchType:(OBASearchControllerSearchType)searchType;
- (void) requestPath:(NSString*)path withArgs:(NSString*)args searchType:(OBASearchControllerSearchType)searchType jsonDataSource:(OBAJsonDataSource*)jsonDataSource;

-(NSString*) progressCompleteMessageForSearchType;

-(void) handleSearchByCurrentLocation:(id)jsonObject;
-(void) handleSearchByLocationRegion:(id)jsonObject;
-(void) handleSearchByRoute:(id)jsonObject;
-(void) handleSearchByRouteStops:(id)jsonObject;
-(void) handleSearchByStopId:(id)jsonObject;
-(void) handleSearchByAddress:(id)jsonObject;
-(void) handleSearchByPlacemark:(id)jsonObject;
-(void) handleSearchForAgenciesWithCoverage:(id)jsonObject;

-(NSArray*) parseStops:(NSArray*)stopArray;

-(void) fireStopsFromJsonObject:(id)jsonObject;
-(void) fireStops:(NSArray*)stops limitExceeded:(BOOL)limitExceeded;
-(void) firePlacemarks:(NSArray*)placemarks;
-(void) fireStops:(NSArray*)stops placemarks:(NSArray*)placemarks limitExceeded:(BOOL)limitExceeded;
-(void) fireAgenciesWithCoverage:(NSArray*)agenciesWithCoverage;
-(void) fireUpdate:(OBASearchControllerResult*)result;

- (NSString*) escapeStringForUrl:(NSString*)url;

@end


#pragma mark OBASearchControllerImpl

@implementation OBASearchControllerImpl

@synthesize delegate = _delegate;

@synthesize searchType = _searchType;
@synthesize result = _result;
@synthesize progress = _progress;
@synthesize error = _error;


- (id) initWithAppContext:(OBAApplicationContext*)context {
	
	if ( self = [super init] ) {
		_appContext = [context retain];
		_searchType = OBASearchControllerSearchTypeNone;
		_progress = [[OBAProgressIndicatorImpl alloc] init];
		_locationManager = [context.locationManager retain];
		_modelFactory = [context.modelFactory retain];
		
		_obaDataSource = [[OBAJsonDataSource alloc] initWithConfig:context.obaDataSourceConfig];
		_googleMapsDataSource = [[OBAJsonDataSource alloc] initWithConfig:context.googleMapsDataSourceConfig];
	}
	return self;
}

-(void) dealloc {
	
	[self cancelOpenConnections];

	[_appContext release];
	
	[_progress release];
	[_locationManager release];
	[_modelFactory release];
	
	[_obaDataSource release];
	[_googleMapsDataSource release];
	
	[_target release];
	[_searchContext release];
	[_lastCurrentLocationSearch release];
	[_result release];
	
	[super dealloc];
}

-(void) searchWithTarget:(OBANavigationTarget*)target {
	
	_target = [NSObject releaseOld:_target retainNew:target];
	
	// Update our target parameters
	NSDictionary * parameters = target.parameters;	
	NSNumber * searchTypeAsNumber = [parameters objectForKey:kOBASearchControllerSearchTypeParameter];
	
	if( ! searchTypeAsNumber )
		searchTypeAsNumber = [NSNumber numberWithInt:OBASearchControllerSearchTypeCurrentLocation];
	
	OBASearchControllerSearchType searchType = [self searchTypeForNumber:searchTypeAsNumber];
	
	@synchronized(self) {
		
		[self cancelOpenConnections];

		if( _searchType == OBASearchControllerSearchTypeCurrentLocation && searchType != OBASearchControllerSearchTypeCurrentLocation)
			[_locationManager removeDelegate:self];
		
		if( _searchType != OBASearchControllerSearchTypeCurrentLocation && searchType == OBASearchControllerSearchTypeCurrentLocation)
			[_locationManager addDelegate:self];
		
		_searchType = searchType;
		_result = [NSObject releaseOld:_result retainNew:nil];
	}	
	
	switch (_searchType) {
		case OBASearchControllerSearchTypeCurrentLocation:
			[self searchByCurrentLocation];
			break;
		case OBASearchControllerSearchTypeRegion: {
			NSData * data = [parameters objectForKey:kOBASearchControllerSearchArgumentParameter];
			MKCoordinateRegion region;
			[data getBytes:&region];
			[self searchByLocationRegion:region];
			break;
		}
		case OBASearchControllerSearchTypeRoute: {
			NSString * routeQuery = [parameters objectForKey:kOBASearchControllerSearchArgumentParameter];
			[self searchByRoute:routeQuery];
			break;			
		}
		case OBASearchControllerSearchTypeRouteStops: {
			NSString * routeId = [parameters objectForKey:kOBASearchControllerSearchArgumentParameter];
			[self searchByRouteStops:routeId];
			break;						
		}
		case OBASearchControllerSearchTypeAddress: {
			NSString * addressQuery = [parameters objectForKey:kOBASearchControllerSearchArgumentParameter];
			[self searchByAddress:addressQuery];
			break;						
		}
		case OBASearchControllerSearchTypePlacemark: {
			OBAPlacemark * placemark = [parameters objectForKey:kOBASearchControllerSearchArgumentParameter];
			[self searchByPlacemark:placemark];
			break;						
		}			
		case OBASearchControllerSearchTypeStopId: {
			NSString * stopCode = [parameters objectForKey:kOBASearchControllerSearchArgumentParameter];
			[self searchByStopId:stopCode];
			break;						
		}
		case OBASearchControllerSearchTypeAgenciesWithCoverage:
			[self searchForAgenciesWithCoverage];
			break;
		default:
			break;
	}	
}

-(OBANavigationTarget*) getSearchTarget {
	return _target;
}

-(CLLocation*) searchLocation {
	return [_target parameterForKey:kOBASearchControllerSearchLocationParameter];
}

- (void) setSearchLocation:(CLLocation*)location { 
	if( location ) 
		[_target setParameter:location forKey:kOBASearchControllerSearchLocationParameter];
}

- (void) cancelOpenConnections {
	NSLog(@"Canceling open connections from SearchController");
	[_obaDataSource cancelOpenConnections];
	[_googleMapsDataSource cancelOpenConnections];
}

#pragma mark OBALocationManagerDelegate Methods

- (void)locationManager:(OBALocationManager *)manager didUpdateLocation:(CLLocation *)location {
	
	self.searchLocation = location;
	
	if( _searchType == OBASearchControllerSearchTypeCurrentLocation ) {
		if( _lastCurrentLocationSearch == nil || [_lastCurrentLocationSearch getDistanceFrom:location] > kSearchRadius * 0.25 )
			[self searchByCurrentLocation];
	}
}


#pragma mark OBADataSourceDelegate Methods

- (void)connection:(id<OBADataSourceConnection>)connection withProgress:(float)progress {
	[_progress setInProgress:TRUE progress:progress];
}

- (void)connectionDidFinishLoading:(id<OBADataSourceConnection>)connection withObject:(id)obj context:(id)context {
	
	OBASearchControllerSearchType searchType = OBASearchControllerSearchTypeNone;
	
	@synchronized(self) {		
		if( ! [context isEqual:_searchContext] )
			return;
		searchType = _searchType;
	}
	
	
	//NSString * message = [NSString stringWithFormat:@"Updated: %@", [OBACommon getTimeAsString]];
	NSString * message = [self progressCompleteMessageForSearchType];
	[_progress setMessage:message inProgress:FALSE progress:0];
	
	switch (searchType ) {
		case OBASearchControllerSearchTypeCurrentLocation:
			[self handleSearchByCurrentLocation:obj];
			break;
		case OBASearchControllerSearchTypeRegion:
			[self handleSearchByLocationRegion:obj];
			break;
		case OBASearchControllerSearchTypeRoute:
			[self handleSearchByRoute:obj];
			break;
		case OBASearchControllerSearchTypeRouteStops:
			[self handleSearchByRouteStops:obj];
			break;				
		case OBASearchControllerSearchTypeAddress:
			[self handleSearchByAddress:obj];
			break;
		case OBASearchControllerSearchTypePlacemark:
			[self handleSearchByPlacemark:obj];
			break;
		case OBASearchControllerSearchTypeStopId:
			[self handleSearchByStopId:obj];
			break;
		case OBASearchControllerSearchTypeAgenciesWithCoverage:
			[self handleSearchForAgenciesWithCoverage:obj];
			break;
	}
}

- (void)connectionDidFail:(id<OBADataSourceConnection>)connection withError:(NSError *)localError context:(id)context {
	NSLog(@"Connection failed! Error - %@ %@", [localError localizedDescription],[[localError userInfo] objectForKey:NSErrorFailingURLStringKey]);
	[_progress setMessage:@"Error connecting" inProgress:FALSE progress:0];
}

@end

@implementation OBASearchControllerImpl (Internal)

- (OBASearchControllerSearchType) searchTypeForNumber:(NSNumber*)number {
	switch ([number intValue]) {
		case OBASearchControllerSearchTypeCurrentLocation:
			return OBASearchControllerSearchTypeCurrentLocation;
		case OBASearchControllerSearchTypeRegion:
			return OBASearchControllerSearchTypeRegion;
		case OBASearchControllerSearchTypeRoute:
			return OBASearchControllerSearchTypeRoute;
		case OBASearchControllerSearchTypeRouteStops:
			return OBASearchControllerSearchTypeRouteStops;
		case OBASearchControllerSearchTypeAddress:
			return OBASearchControllerSearchTypeAddress;
		case OBASearchControllerSearchTypePlacemark:
			return OBASearchControllerSearchTypePlacemark;
		case OBASearchControllerSearchTypeStopId:
			return OBASearchControllerSearchTypeStopId;
		case OBASearchControllerSearchTypeAgenciesWithCoverage:
			return OBASearchControllerSearchTypeAgenciesWithCoverage;
		default:
			return OBASearchControllerSearchTypeNone;
	}		
}

- (CLLocation*) currentLocationToSearch {
	CLLocation * location = _locationManager.currentLocation;
	if( location )
		self.searchLocation = location;	
	return location;
}

- (CLLocation*) currentOrDefaultLocationToSearch {
	
	CLLocation * location = _locationManager.currentLocation;
	
	if( ! location )  {
		OBAModelDAO * modelDao = _appContext.modelDao;
		location = modelDao.mostRecentLocation;
	}
	
	if( ! location )
		location = [[[CLLocation alloc] initWithLatitude:47.61229680032385  longitude:-122.3386001586914] autorelease];
	
	self.searchLocation = location;

	return location;
}

-(void) searchByCurrentLocation {
	
	CLLocation * location =  [self currentLocationToSearch];

	if( ! location) {
		if( _locationManager.locationServicesEnabled )
			[_progress setMessage:@"Locating..." inProgress:TRUE progress:0];
		else
			[_progress setMessage:@"Location services disabled" inProgress:FALSE progress:0];
		return;
	}
	
	CLLocationCoordinate2D coord = location.coordinate;
	
	_lastCurrentLocationSearch = [NSObject releaseOld:_lastCurrentLocationSearch retainNew:location];
	
	NSString * args = [NSString stringWithFormat:@"lat=%f&lon=%f&radius=%f", coord.latitude, coord.longitude,kSearchRadius];
	[self requestPath:@"/api/where/stops-for-location.json" withArgs:args searchType:OBASearchControllerSearchTypeCurrentLocation];
}

-(void) searchByLocationRegion:(MKCoordinateRegion)region {
	
	CLLocationCoordinate2D coord = region.center;
	MKCoordinateSpan span = region.span;
	
	NSString * args = [NSString stringWithFormat:@"lat=%f&lon=%f&latSpan=%f&lonSpan=%f", coord.latitude, coord.longitude,span.latitudeDelta,span.longitudeDelta];
	[self requestPath:@"/api/where/stops-for-location.json" withArgs:args searchType:OBASearchControllerSearchTypeRegion];
}

-(void) searchByRoute:(NSString*)routeQuery {
	CLLocation * location = [self currentOrDefaultLocationToSearch];
	CLLocationCoordinate2D coord = location.coordinate;
	routeQuery = [self escapeStringForUrl:routeQuery];
	NSString * args = [NSString stringWithFormat:@"lat=%f&lon=%f&query=%@", coord.latitude, coord.longitude,routeQuery];
	[self requestPath:@"/api/where/routes-for-location.json" withArgs:args searchType:OBASearchControllerSearchTypeRoute];
}

-(void) searchByRouteStops:(NSString*)routeId {
	
	NSString * path = [NSString stringWithFormat:@"/api/where/stops-for-route/%@.json", routeId];
	[self requestPath: path withArgs:nil searchType:OBASearchControllerSearchTypeRouteStops];		
	
}

-(void) searchByStopId:(NSString*)stopIdQuery {
	
	CLLocation * location = [self currentOrDefaultLocationToSearch];
	CLLocationCoordinate2D coord = location.coordinate;
	stopIdQuery = [self escapeStringForUrl:stopIdQuery];
	NSString * args = [NSString stringWithFormat:@"lat=%f&lon=%f&query=%@", coord.latitude, coord.longitude,stopIdQuery];
	[self requestPath:@"/api/where/stops-for-location.json" withArgs:args searchType:OBASearchControllerSearchTypeStopId];
}

-(void) searchByAddress:(NSString*)addressQuery {
	CLLocation * location = [self currentOrDefaultLocationToSearch];
	CLLocationCoordinate2D coord = location.coordinate;
	addressQuery = [self escapeStringForUrl:addressQuery];
	NSString * args = [NSString stringWithFormat:@"ll=%f,%f&spn=0.5,0.5&q=%@", coord.latitude, coord.longitude,addressQuery];
	[self requestPath:@"/maps/geo" withArgs:args searchType:OBASearchControllerSearchTypeAddress jsonDataSource:_googleMapsDataSource];
}

-(void) searchByPlacemark:(OBAPlacemark*)placemark {
	
	// Log the placemark
	[_appContext.activityListeners placemark:placemark];
	
	CLLocationCoordinate2D location = placemark.coordinate;
	MKCoordinateRegion region = [OBASphericalGeometryLibrary createRegionWithCenter:location latRadius:kSearchRadius lonRadius:kSearchRadius];
	MKCoordinateSpan span = region.span;
	NSString * args = [NSString stringWithFormat:@"lat=%f&lon=%f&latSpan=%f&lonSpan=%f", location.latitude, location.longitude,span.latitudeDelta,span.longitudeDelta];
	[self requestPath:@"/api/where/stops-for-location.json" withArgs:args searchType:OBASearchControllerSearchTypePlacemark];
}

-(void) searchForAgenciesWithCoverage {
	[self requestPath:@"/api/where/agencies-with-coverage.json" withArgs:nil searchType:OBASearchControllerSearchTypeAgenciesWithCoverage];
}

- (void) requestPath:(NSString*)path withArgs:(NSString*)args searchType:(OBASearchControllerSearchType)searchType {
	[self requestPath:path withArgs:args searchType:searchType jsonDataSource:_obaDataSource];
}

- (void) requestPath:(NSString*)path withArgs:(NSString*)args searchType:(OBASearchControllerSearchType)searchType jsonDataSource:(OBAJsonDataSource*)jsonDataSource {
	
	@synchronized(self) {
		
		
		[_searchContext release];
		if( args )
			_searchContext = [[NSString alloc] initWithFormat:@"%@?%@",path,args];
		else
			_searchContext = [path retain];
		
		[jsonDataSource requestWithPath:path withArgs:args withDelegate:self context:_searchContext];
		
		[_progress setMessage:@"Connecting..." inProgress:TRUE progress:0];
	}
}

-(NSString*) progressCompleteMessageForSearchType {

	NSString * title = nil;
	
	switch (_searchType) {
		case OBASearchControllerSearchTypeNone:
			title = @"";
			break;
		case OBASearchControllerSearchTypeCurrentLocation:
		case OBASearchControllerSearchTypeRegion:
		case OBASearchControllerSearchTypePlacemark:
		case OBASearchControllerSearchTypeStopId:			
		case OBASearchControllerSearchTypeRouteStops:
			title = @"Stops";
			break;
		case OBASearchControllerSearchTypeRoute:		
			title = @"Routes";
			break;
		case OBASearchControllerSearchTypeAddress:
			title = @"Places";
			break;
		case OBASearchControllerSearchTypeAgenciesWithCoverage:
			title = @"Agencies";
			break;
		default:			
			break;
	}
	
	return title;
}

-(void) handleSearchByCurrentLocation:(id)jsonObject {
	[self fireStopsFromJsonObject:jsonObject];
}

-(void) handleSearchByLocationRegion:(id)jsonObject {
	[self fireStopsFromJsonObject:jsonObject];
}

-(void) handleSearchByRoute:(id)jsonObject {
	
	NSArray * data = [jsonObject valueForKey:@"data"];
	
	if( ! data || [data isEqual:[NSNull null]])
		return;
	
	NSError * localError = nil;
	NSArray * routes = [_modelFactory getRoutesFromJSONArray:data error:&localError];
	
	if( localError ) {
		self.error = localError;
		return;
	}
	
	if( [routes count] == 1 ) {
		OBARoute * route = [routes objectAtIndex:0];
		OBANavigationTarget * target = [OBASearchControllerFactory getNavigationTargetForSearchRouteStops:route.routeId];
		[self searchWithTarget: target];
	}
	else {
		OBASearchControllerResult * result = [OBASearchControllerResult result];
		result.routes = routes;
		[self fireUpdate:result];
	}
}

-(void) handleSearchByRouteStops:(id)jsonObject {
	
	NSDictionary * data = [jsonObject valueForKey:@"data"];
	
	if( ! data || [data isEqual:[NSNull null]])
		return;
	
	NSArray * stopsArray = [data objectForKey:@"stops"];
	
	if( stopsArray ) {
		NSError * localError = nil;	
		NSArray * newStops = [_modelFactory getStopsFromJSONArray:stopsArray error:&localError];
		
		if( localError ) {
			self.error = localError;
			return;
		}
		
		
		[self fireStops:newStops limitExceeded:FALSE];
	}
}

-(void) handleSearchByStopId:(id)jsonObject {
	[self fireStopsFromJsonObject:jsonObject];
}

-(void) handleSearchByAddress:(id)jsonObject {
	
	if( ! jsonObject )
		return;
	
	NSError * localError = nil;
	NSArray * placemarks = [_modelFactory getPlacemarksFromJSONObject:jsonObject error:&localError];
	
	if( localError ) {
		self.error = localError;
		return;
	}
	
	if( [placemarks count] == 1 ) {
		OBAPlacemark * placemark = [placemarks objectAtIndex:0];
		OBANavigationTarget * target = [OBASearchControllerFactory getNavigationTargetForSearchPlacemark:placemark];
		[self searchWithTarget:target];
	}
	else {
		[self firePlacemarks:placemarks];
	}
}

-(void) handleSearchByPlacemark:(id)jsonObject {
	NSDictionary * data = [jsonObject valueForKey:@"data"];
	NSArray * stopsArray = [data objectForKey:@"stops"];
	NSArray * stops = [self parseStops:stopsArray];
	NSNumber * limitExceeded = [data objectForKey:@"limitExceeded"];
	OBAPlacemark * placemark = [_target parameterForKey:kOBASearchControllerSearchArgumentParameter];
	NSArray * placemarks = [NSArray arrayWithObject:placemark];
	[self fireStops:stops placemarks:placemarks limitExceeded:[limitExceeded boolValue]];
}

-(void) handleSearchForAgenciesWithCoverage:(id)jsonObject {
	
	NSArray * data = [jsonObject objectForKey:@"data"];
	
	NSError * localError = nil;
	NSArray * agenciesWithCoverage = [_modelFactory getAgenciesWithCoverageFromJson:data error:&localError];
	
	if( localError ) {
		self.error = localError;
		return;
	}
	
	[self fireAgenciesWithCoverage:agenciesWithCoverage];
}

-(NSArray*) parseStops:(NSArray*)stopArray {
	
	NSError * localError = nil;	
	NSArray * newStops = [_modelFactory getStopsFromJSONArray:stopArray error:&localError];
	
	if( localError ) {
		OBALogSevereWithError(localError,@"This is bad");
		self.error = localError;
		return [NSArray array];
	}
	
	newStops = [newStops sortedArrayUsingSelector:@selector(compareUsingName:)];
	
	return newStops;
}

-(void) fireStopsFromJsonObject:(id)jsonObject {
	NSDictionary * data = [jsonObject valueForKey:@"data"];
	NSArray * stopsArray = [data objectForKey:@"stops"];
	NSArray * stops = [self parseStops:stopsArray];
	NSNumber * v = [data objectForKey:@"limitExceeded"];
	BOOL limitExceeded = [v boolValue];
	[self fireStops:stops limitExceeded:limitExceeded];
}

-(void) fireStops:(NSArray*)stops limitExceeded:(BOOL)limitExceeded {
	OBASearchControllerResult * result = [OBASearchControllerResult result];
	result.stops = stops;
	result.stopLimitExceeded = limitExceeded;
	[self fireUpdate:result];
}

-(void) firePlacemarks:(NSArray*)placemarks {
	OBASearchControllerResult * result = [OBASearchControllerResult result];
	result.placemarks = placemarks;
	[self fireUpdate:result];
}

-(void) fireStops:(NSArray*)stops placemarks:(NSArray*)placemarks limitExceeded:(BOOL)limitExceeded {
	OBASearchControllerResult * result = [OBASearchControllerResult result];
	result.stops = stops;
	result.placemarks = placemarks;
	result.stopLimitExceeded = limitExceeded;
	[self fireUpdate:result];
}

-(void ) fireAgenciesWithCoverage:(NSArray*)agenciesWithCoverage {
	OBASearchControllerResult * result = [OBASearchControllerResult result];
	result.agenciesWithCoverage = agenciesWithCoverage;
	[self fireUpdate:result];
}

-(void) fireUpdate:(OBASearchControllerResult*)result {
	result.searchType = _searchType;
	_result = [NSObject releaseOld:_result retainNew:result];
	if( _delegate )
		[_delegate handleSearchControllerUpdate:_result];
}

- (NSString*) escapeStringForUrl:(NSString*)url {
	url = [url stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
	NSMutableString *escaped = [NSMutableString stringWithString:url];
	NSRange wholeString = NSMakeRange(0, [escaped length]);
	[escaped replaceOccurrencesOfString:@"&" withString:@"%26" options:NSCaseInsensitiveSearch range:wholeString];
	[escaped replaceOccurrencesOfString:@"+" withString:@"%2B" options:NSCaseInsensitiveSearch range:wholeString];
	[escaped replaceOccurrencesOfString:@"," withString:@"%2C" options:NSCaseInsensitiveSearch range:wholeString];
	[escaped replaceOccurrencesOfString:@"/" withString:@"%2F" options:NSCaseInsensitiveSearch range:wholeString];
	[escaped replaceOccurrencesOfString:@":" withString:@"%3A" options:NSCaseInsensitiveSearch range:wholeString];
	[escaped replaceOccurrencesOfString:@";" withString:@"%3B" options:NSCaseInsensitiveSearch range:wholeString];
	[escaped replaceOccurrencesOfString:@"=" withString:@"%3D" options:NSCaseInsensitiveSearch range:wholeString];
	[escaped replaceOccurrencesOfString:@"?" withString:@"%3F" options:NSCaseInsensitiveSearch range:wholeString];
	[escaped replaceOccurrencesOfString:@"@" withString:@"%40" options:NSCaseInsensitiveSearch range:wholeString];
	[escaped replaceOccurrencesOfString:@" " withString:@"%20" options:NSCaseInsensitiveSearch range:wholeString];
	[escaped replaceOccurrencesOfString:@"\t" withString:@"%09" options:NSCaseInsensitiveSearch range:wholeString];
	[escaped replaceOccurrencesOfString:@"#" withString:@"%23" options:NSCaseInsensitiveSearch range:wholeString];
	[escaped replaceOccurrencesOfString:@"<" withString:@"%3C" options:NSCaseInsensitiveSearch range:wholeString];
	[escaped replaceOccurrencesOfString:@">" withString:@"%3E" options:NSCaseInsensitiveSearch range:wholeString];
	[escaped replaceOccurrencesOfString:@"\"" withString:@"%22" options:NSCaseInsensitiveSearch range:wholeString];
	[escaped replaceOccurrencesOfString:@"\n" withString:@"%0A" options:NSCaseInsensitiveSearch range:wholeString];
	return escaped;
}

@end