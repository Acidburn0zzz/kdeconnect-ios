//
//  Reminder.m
//  kdeconnect-ios
//
//  Created by YANG Qiao on 7/9/14.
//  Copyright (c) 2014 yangqiao. All rights reserved.
//

#import "Reminder.h"
#import "Device.h"
#import <EventKit/EventKit.h>
#import <EventKitUI/EventKitUI.h>
#import "XBICalendar.h"
#import "XbICComponent+VTodo.h"

@interface Reminder ()
@property(nonatomic)EKEventStore *_eventStore;
@property(nonatomic)EKCalendar *_calendar;
@property(nonatomic)NSArray *_reminderList;
@property(nonatomic)NSMutableArray *_invalideUids;
@property(nonatomic)BOOL _requested;
@end

@implementation Reminder
@synthesize _device;
@synthesize _pluginInfo;
@synthesize _pluginDelegate;
@synthesize _calendar;
@synthesize _reminderList;
@synthesize _eventStore;
@synthesize _invalideUids;
@synthesize _requested;

- (id) init
{
    if ((self=[super init])) {
        _pluginDelegate=nil;
        _device=nil;
        _eventStore = [[EKEventStore alloc] init];
        _reminderList = [NSArray array];
        _invalideUids = [NSMutableArray array];
        _requested=false;
        [[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(storeChanged:)
                                                    name:EKEventStoreChangedNotification  object:_eventStore];
        [self checkEventStoreAccessForCalendar];
    }
    return self;
}

- (BOOL) onDevicePackageReceived:(NetworkPackage *)np
{
    if ([[np _Type] isEqualToString:PACKAGE_TYPE_REMINDER]) {
        NSLog(@"Reminder plugin receive a package");
        if ([np bodyHasKey:@"request"]) {
            _requested=true;
        }
        else {
            NSError* err;
            EKReminder* reminder=[Reminder retrieveEvent:np withStore:_eventStore error:&err];
            
            if ([err.domain isEqualToString:@"iCal parse failed"]) {
                return true;
            }

            if ([[np objectForKey:@"op"] isEqualToString:@"delete"]){
                [_eventStore removeReminder:reminder commit:YES error:&err];
                if (err) {
                    NSLog(@"Reminder plugin:delete reminder error");
                }
            }
            else if ([[np objectForKey:@"op"] isEqualToString:@"merge"]){
                if ([err.domain isEqualToString:@"iCal fix uid"]) {
                    NSString* uid=[[err userInfo] objectForKey:@"uid"];
                    if (![_invalideUids containsObject:uid]) {
                        NetworkPackage* np=[[NetworkPackage alloc] initWithType:PACKAGE_TYPE_REMINDER];
                        [np setObject:@"delete" forKey:@"op"];
                        [np setObject:uid forKey:@"uid"];
                        [_device sendPackage:np tag:PACKAGE_TAG_REMINDER];
                        [_invalideUids addObject:uid];
                    }
                }
                EKReminder* oldreminder=[_eventStore calendarItemWithIdentifier:reminder.calendarItemIdentifier];
                if (!oldreminder){
                    [_eventStore saveReminder:reminder commit:YES error:&err];
                }
                else if (![Reminder reminder:reminder isIdenToReminder2:oldreminder]){
                    [_eventStore saveReminder:reminder commit:YES error:&err];
                }
                else if ( [err.domain isEqualToString: @"iCal peer outdated"]){
                    [self sendReminder];
                }
            }
        }
        return true;
    }
    return false;
}

+ (PluginInfo*) getPluginInfo
{
    return [[PluginInfo alloc] initWithInfos:@"Reminder" displayName:@"Reminder" description:@"Reminder" enabledByDefault:true];
}

// Check the authorization status of our application for Calendar
-(void)checkEventStoreAccessForCalendar
{
    EKAuthorizationStatus status = [EKEventStore authorizationStatusForEntityType:EKEntityTypeReminder];
    
    switch (status)
    {
            // Update our UI if the user has granted access to their Reminder
        case EKAuthorizationStatusAuthorized: [self accessGrantedForReminder];
            break;
            // Prompt the user for access to Reminder if there is no definitive answer
        case EKAuthorizationStatusNotDetermined: [self requestReminderAccess];
            break;
            // Display a message if the user has denied or restricted access to Reminder
        case EKAuthorizationStatusDenied:
        case EKAuthorizationStatusRestricted:
        {
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Privacy Warning" message:@"Permission was not granted for calendar"
                                                           delegate:nil
                                                  cancelButtonTitle:@"OK"
                                                  otherButtonTitles:nil];
            [alert show];
        }
            break;
        default:
            break;
    }
}

// Prompt the user for access to their Reminder
-(void)requestReminderAccess
{
    [_eventStore requestAccessToEntityType:EKEntityTypeReminder completion:^(BOOL granted, NSError *error)
     {
         if (granted)
         {
             [self accessGrantedForReminder];
         }
     }];
}

// This method is called when the user has granted permission to Reminder
-(void)accessGrantedForReminder
{
    // Let's get the default calendar associated with our calendar store
    _calendar = [_eventStore defaultCalendarForNewReminders];
    // Fetch all events happening in the next 24 hours and put them into eventsList
    [self fetchReminders];
}

// Fetch all reminders happening in the next 24 hours
- (void) fetchReminders
{
    NSPredicate *predicate = [_eventStore predicateForRemindersInCalendars:nil];
    
    // Fetch all events that match the predicate
    [_eventStore fetchRemindersMatchingPredicate:predicate completion:^(NSArray *reminders) {
        _reminderList=reminders;
        [self fetchCompleted];
    }];
}

- (void) fetchCompleted
{
    if ([_reminderList count]==0) {
        NetworkPackage* np2=[[NetworkPackage alloc] initWithType:PACKAGE_TYPE_CALENDAR];
        [np2 setBool:YES forKey:@"request"];
        [_device sendPackage:np2 tag:PACKAGE_TAG_CALENDAR];
    }
    if (_requested) {
        _requested=false;
        [self sendReminder];
    }
}

- (void) storeChanged:(id) sender
{
    _requested=true;
    [self fetchReminders];
    
}

- (void) sendReminder
{
    for (EKReminder* r in _reminderList) {
        NetworkPackage* np=[Reminder createNetworkPackage:r];
        [np setObject:@"merge" forKey:@"op"];
        [_device sendPackage:np tag:PACKAGE_TAG_REMINDER];
    }
}

+ (BOOL) reminder:(EKReminder*) reminder1 isIdenToReminder2:(EKReminder*) reminder2
{
    if (![reminder1.title isEqualToString:reminder2.title]||
        ![reminder1.dueDateComponents.date isEqualToDate:reminder2.dueDateComponents.date]) {
        return false;
    }
    return true;
}

+ (EKReminder*) retrieveEvent:(NetworkPackage*)np withStore:(EKEventStore*) eventstore error:( NSError*__autoreleasing*)err
{
    return [Reminder iCalToReminder:[np objectForKey:@"iCal"] withStore:eventstore error:err];
}

+ (NetworkPackage*) createNetworkPackage: (EKReminder*)event
{
    NetworkPackage* np=[[NetworkPackage alloc] initWithType:PACKAGE_TYPE_REMINDER];
    NSString* ical=[Reminder reminderToiCal:event];
    if (!ical) {
        return nil;
    }
    [np setObject:ical forKey:@"iCal"];
    return np;
}

+ (EKReminder*) iCalToReminder: (NSString*) iCal withStore:(EKEventStore*) eventstore error:( NSError*__autoreleasing*)err
{
    XbICVCalendar * vCalendar =  [XbICVCalendar vCalendarFromString:iCal];
    XbICComponent* xbicvtodo=[vCalendar firstComponentOfKind:ICAL_VTODO_COMPONENT];
    
    
    NSString* uid=[xbicvtodo UID];
    NSString* summary=xbicvtodo.summary;
    NSDate* dt_s=xbicvtodo.dateStart;
    NSDate* dt_due=xbicvtodo.dateDue;
    NSDate* dt_created=xbicvtodo.dateCreated;
    NSDate* dt_modified=xbicvtodo.dateLastModified;
    NSNumber* percent=xbicvtodo.percentCompleted;
    NSCalendar *gregorian = [[NSCalendar alloc]
                             initWithCalendarIdentifier:NSGregorianCalendar];
    NSDateComponents* start_dtc=[gregorian components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay|NSCalendarUnitHour|NSCalendarUnitMinute|NSCalendarUnitSecond fromDate:dt_s];
    [start_dtc setTimeZone:[NSTimeZone localTimeZone]];
    [start_dtc setCalendar:gregorian];
    NSDateComponents* due_dtc=[gregorian components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay|NSCalendarUnitHour|NSCalendarUnitMinute|NSCalendarUnitSecond fromDate:dt_due];
    [due_dtc setTimeZone:[NSTimeZone localTimeZone]];
    [due_dtc setCalendar:gregorian];
    
    if (!uid||!summary||!dt_due) {
        *err=[[NSError alloc] initWithDomain:@"iCal parse failed" code:0 userInfo:nil];
        return nil;
    }
    EKReminder* reminder=[eventstore calendarItemWithIdentifier:uid];
    if (!reminder) {
        reminder=[EKReminder reminderWithEventStore:eventstore];
        [reminder setCalendar:[eventstore defaultCalendarForNewReminders]];
        [reminder setTitle:summary];
        [reminder setStartDateComponents:start_dtc];
        [reminder setDueDateComponents:due_dtc];
        *err=[[NSError alloc] initWithDomain:@"iCal fix uid" code:1 userInfo:@{@"uid": uid}];
        return reminder;
    }
    if ( (![reminder.title isEqualToString:summary]||
        ![reminder.dueDateComponents.date isEqualToDate:due_dtc.date])
          && [reminder.lastModifiedDate compare:dt_modified]==NSOrderedAscending) {
        [reminder setCalendar:[eventstore defaultCalendarForNewReminders]];
        [reminder setTitle:summary];
        [reminder setStartDateComponents:start_dtc];
        [reminder setDueDateComponents:due_dtc];
    }
    if ([reminder.lastModifiedDate compare:dt_modified]==NSOrderedDescending) {
        *err=[[NSError alloc] initWithDomain:@"iCal peer outdated" code:1 userInfo:nil];
    }
    return reminder;
}

+ (NSString*) reminderToiCal: (EKReminder*)reminder
{
    if (!reminder || [reminder.title isEqualToString:@""]) {
        return nil;
    }
    NSDateFormatter* df=[[NSDateFormatter alloc] init];
    NSTimeZone *timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    [df setTimeZone:timeZone];
    [df setDateFormat:@"yyyyMMdd'T'HHmmss'Z'"];
    NSString* dt_stamp=[df stringFromDate:[NSDate date]];
    NSString* dt_create=[df stringFromDate:reminder.creationDate];
    NSString* dt_modified=[df stringFromDate:reminder.lastModifiedDate];
    NSString* dt_start=[df stringFromDate:reminder.startDateComponents.date];
    NSString* dt_due=[df stringFromDate:reminder.dueDateComponents.date];
    NSString* t=reminder.title;
    NSMutableString* iCal=[NSMutableString string];
    [iCal appendString:@"BEGIN:VCALENDAR\n"];
    [iCal appendString:@"VERSION:2.0\n"];
    [iCal appendString:@"PRODID:-//kde//kdeconnect-ios v0.1/EN\n"];
    [iCal appendString:@"BEGIN:VTODO\n"];
    [iCal appendFormat:@"DTSTAMP:%@\n",dt_stamp];
    [iCal appendFormat:@"CREATED:%@\n",dt_create];
    [iCal appendFormat:@"LAST-MODIFIED:%@\n",dt_modified];
    [iCal appendFormat:@"DUE:%@\n",dt_due];
    [iCal appendFormat:@"DTSTART:%@\n",dt_start];
    [iCal appendFormat:@"UID:%@\n",reminder.calendarItemIdentifier];
    [iCal appendFormat:@"SUMMARY:%@\n",t];
    [iCal appendString:@"END:VTODO\n"];
    [iCal appendString:@"END:VCALENDAR\n"];
    return iCal;
}

@end

