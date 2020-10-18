//
//  RunCommand.m
//  kdeconnect-ios
//
//  Created by Inoki on 18/10/2020.
//  Copyright © 2020 Inoki. All rights reserved.
//

#import "RunCommand.h"
#import "NetworkPackage.h"
#import "Device.h"

@interface RunCommand()
@property(nonatomic) UIView* _view;
@end

@implementation RunCommand

@synthesize _device;
@synthesize _pluginDelegate;
@synthesize _view;
@synthesize _lockScreenString;

- (id) init
{
    if ((self=[super init])) {
        _pluginDelegate = nil;
        _device = nil;
        _view = nil;
        _lockScreenString = @"";
    }
    return self;
}

- (BOOL) onDevicePackageReceived:(NetworkPackage *)np
{
    if ([[np _Type] isEqualToString:PACKAGE_TYPE_RUNCOMMAND]) {
        NSLog(@"runcommand plugin receive a package");
        NSString *commandsJson = [np objectForKey:@"commandList"];
        NSError* err=nil;
        NSDictionary* commands=[NSJSONSerialization JSONObjectWithData:[commandsJson dataUsingEncoding:kCFStringEncodingUTF8]
                                                options:NSJSONReadingMutableContainers error:&err];

        for (NSString *command in commands)
        {
            NSLog(@"%@", command);

            _lockScreenString = command;
            break;
        }
        return true;
    }
    return false;
}

- (UIView*) getView:(UIViewController*)vc
{
    if ([_device isReachable]) {
        _view = [[UIStackView alloc] initWithFrame:CGRectMake(0, 0, screen_width, 60)];
        UIStackView *stackView = (UIStackView *)_view;
        stackView.axis = UILayoutConstraintAxisVertical;
        stackView.alignment = UIStackViewAlignmentFill;

        UILabel* label=[[UILabel alloc] init];
        [label setText:NSLocalizedString(@"Run Command",nil)];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        [button setTitle:NSLocalizedString(@"Lock Screen",nil) forState:UIControlStateNormal];
        button.layer.borderWidth = 1;
        button.layer.cornerRadius = 10.0;
        button.layer.borderColor = [[UIColor grayColor] CGColor];
        //[button addTarget:self action:@selector(openSetupWindow:) forControlEvents:UIControlEventTouchUpInside];
        [button addTarget:self action:@selector(lockScreen:) forControlEvents:UIControlEventTouchUpInside];

        stackView.distribution = UIStackViewDistributionFillProportionally;
        [stackView addArrangedSubview:label];
        [stackView addArrangedSubview:button];
        if (isPad) {
            NSArray* constraints=[NSLayoutConstraint constraintsWithVisualFormat:@"|-100-[button]-100-|" options:0 metrics:nil views:@{@"button": button}];
            constraints=[constraints arrayByAddingObjectsFromArray:[NSLayoutConstraint constraintsWithVisualFormat:@"|-50-[label]" options:0 metrics:nil views:@{@"label": label}]];
            [_view addConstraints:constraints];
        }
        if (isPhone) {
            NSArray* constraints=[NSLayoutConstraint constraintsWithVisualFormat:@"|-10-[button]-10-|" options:0 metrics:nil views:@{@"button": button}];
            constraints=[constraints arrayByAddingObjectsFromArray:[NSLayoutConstraint constraintsWithVisualFormat:@"|-5-[label]" options:0 metrics:nil views:@{@"label": label}]];
            [_view addConstraints:constraints];
        }
        label.translatesAutoresizingMaskIntoConstraints=NO;
        button.translatesAutoresizingMaskIntoConstraints=NO;
    }
    else{
        _view=nil;
    }
    return _view;
}

+ (PluginInfo*) getPluginInfo
{
    return [[PluginInfo alloc] initWithInfos:@"Run Command" displayName:NSLocalizedString(@"Run Command",nil) description:NSLocalizedString(@"Run Command on remote deivce",nil) enabledByDefault:true];
}

- (void)openSetupWindow:(id)sender
{
    NetworkPackage* np=[[NetworkPackage alloc] initWithType:PACKAGE_TYPE_RUNCOMMAND_REQUEST];
    [np setBool:YES forKey:@"setup"];
    [_device sendPackage:np tag:PACKAGE_TAG_RUNCOMMAND];
}

- (void)lockScreen:(id)sender
{
    NetworkPackage* np=[[NetworkPackage alloc] initWithType:PACKAGE_TYPE_RUNCOMMAND_REQUEST];
    [np setObject:_lockScreenString forKey:@"key"];
    [_device sendPackage:np tag:PACKAGE_TAG_RUNCOMMAND];
}

@end
