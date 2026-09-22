#import "BuiltInAIM.h"
#import "PatchCore.h"

static NSData *BuiltInPatchResourceData(NSString *name, NSString *section) {
    NSArray<NSString *> *directories = [section isEqualToString:@"FF 2022"]
        ? @[@"FF2022", @"Resources/FF2022"]
        : @[@"FF", @"Resources/FF"];
    NSString *path = nil;
    for (NSString *directory in directories) {
        path = [[NSBundle mainBundle] pathForResource:name
                                               ofType:@"3105"
                                          inDirectory:directory];
        if (path.length) break;
    }
    if (!path.length) {
        path = [[NSBundle mainBundle] pathForResource:name ofType:@"3105"];
    }
    return path.length ? [NSData dataWithContentsOfFile:path
                                               options:NSDataReadingMappedIfSafe
                                                 error:nil] : nil;
}

NSArray<NSDictionary *> *ExternalBuiltInPatchDefinitions(void) {
    static NSArray<NSDictionary *> *definitions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        definitions = @[
            @{
                @"key": @"ff2022_assist",
                @"name": @"ASSIST",
                @"resource": @"FF2022_ASSIST",
                @"projectID": @"7A2A7F2A-9D7F-4F0B-9AF4-5A1E8A5C2201",
                @"section": @"FF 2022",
                @"group": @"ff2022-aim",
                @"warning": @"Clean Safe",
                @"warningColor": @"green"
            },
            @{
                @"key": @"ff2022_drag",
                @"name": @"DRAG",
                @"resource": @"FF2022_DRAG",
                @"projectID": @"7A2A7F2A-9D7F-4F0B-9AF4-5A1E8A5C2202",
                @"section": @"FF 2022",
                @"group": @"ff2022-aim",
                @"warning": @"Clean Safe",
                @"warningColor": @"green"
            },
            @{
                @"key": @"ff2022_neck",
                @"name": @"NECK",
                @"resource": @"FF2022_NECK",
                @"projectID": @"7A2A7F2A-9D7F-4F0B-9AF4-5A1E8A5C2203",
                @"section": @"FF 2022",
                @"group": @"ff2022-aim",
                @"warning": @"Clean Safe",
                @"warningColor": @"green"
            },
            @{
                @"key": @"ff2022_chest",
                @"name": @"CHEST 100%",
                @"resource": @"FF2022_CHEST_100",
                @"projectID": @"7A2A7F2A-9D7F-4F0B-9AF4-5A1E8A5C2204",
                @"section": @"FF 2022",
                @"group": @"ff2022-aim",
                @"warning": @"Clean Safe",
                @"warningColor": @"green"
            },
            @{
                @"key": @"ff2022_vectored",
                @"name": @"VECTORED",
                @"resource": @"FF2022_VECTORED",
                @"projectID": @"7A2A7F2A-9D7F-4F0B-9AF4-5A1E8A5C2205",
                @"section": @"FF 2022",
                @"group": @"ff2022-aim",
                @"warning": @"Clean Safe",
                @"warningColor": @"green"
            },
            @{
                @"key": @"ff2022_silent",
                @"name": @"SILENT",
                @"resource": @"FF2022_SILENT",
                @"projectID": @"7A2A7F2A-9D7F-4F0B-9AF4-5A1E8A5C2206",
                @"section": @"FF 2022",
                @"group": @"ff2022-aim",
                @"warning": @"Clean Safe",
                @"warningColor": @"green"
            },
            @{
                @"key": @"ff2022_remove_aims",
                @"name": @"REMOVE AIMS FF 2022",
                @"resource": @"FF2022_REMOVE_AIMS",
                @"projectID": @"7A2A7F2A-9D7F-4F0B-9AF4-5A1E8A5C2207",
                @"section": @"FF 2022",
                @"group": @"ff2022-aim"
            },
            @{
                @"key": @"apost",
                @"name": @"APOST",
                @"resource": @"APOST",
                @"projectID": @"7A2A7F2A-9D7F-4F0B-9AF4-5A1E8A5C1101",
                @"section": @"FF",
                @"group": @"aim",
                @"warning": @"Clean Safe",
                @"warningColor": @"green"
            },
            @{
                @"key": @"assist",
                @"name": @"ASSIST",
                @"resource": @"ASSIST",
                @"projectID": @"7A2A7F2A-9D7F-4F0B-9AF4-5A1E8A5C1102",
                @"section": @"FF",
                @"group": @"aim",
                @"warning": @"Clean Safe",
                @"warningColor": @"green"
            },
            @{
                @"key": @"trick",
                @"name": @"TRICK",
                @"resource": @"TRICK",
                @"projectID": @"7A2A7F2A-9D7F-4F0B-9AF4-5A1E8A5C1109",
                @"section": @"FF",
                @"group": @"aim",
                @"warning": @"Clean Safe",
                @"warningColor": @"green"
            },
            @{
                @"key": @"drag",
                @"name": @"DRAG",
                @"resource": @"DRAG",
                @"projectID": @"7A2A7F2A-9D7F-4F0B-9AF4-5A1E8A5C1103",
                @"section": @"FF",
                @"group": @"aim",
                @"warning": @"Clean Safe",
                @"warningColor": @"green"
            },
            @{
                @"key": @"neck",
                @"name": @"NECK",
                @"resource": @"NECK",
                @"projectID": @"7A2A7F2A-9D7F-4F0B-9AF4-5A1E8A5C1104",
                @"section": @"FF",
                @"group": @"aim",
                @"warning": @"Clean Safe",
                @"warningColor": @"green"
            },
            @{
                @"key": @"body_disguised",
                @"name": @"BODY DISGUISED",
                @"resource": @"BODY_DISGUISED",
                @"projectID": @"7A2A7F2A-9D7F-4F0B-9AF4-5A1E8A5C1105",
                @"section": @"FF",
                @"group": @"aim",
                @"warning": @"Clean Safe",
                @"warningColor": @"green"
            },
            @{
                @"key": @"remove_aims_ff",
                @"name": @"REMOVE AIMS FF",
                @"resource": @"REMOVE_AIMS_FF",
                @"projectID": @"7A2A7F2A-9D7F-4F0B-9AF4-5A1E8A5C1110",
                @"section": @"FF",
                @"group": @"aim"
            },
            @{
                @"key": @"fps",
                @"name": @"120-144 FPS",
                @"resource": @"120-144_FPS",
                @"projectID": @"7A2A7F2A-9D7F-4F0B-9AF4-5A1E8A5C1107",
                @"section": @"FF",
                @"group": @"fps",
                @"warning": @"This will unlock 120–144 FPS in-game; however, you will lose your current settings, so save them before applying this configuration.",
                @"warningColor": @"yellow"
            },
            @{
                @"key": @"remove_fps",
                @"name": @"REMOVE FPS",
                @"resource": @"REMOVE_FPS",
                @"projectID": @"7A2A7F2A-9D7F-4F0B-9AF4-5A1E8A5C1108",
                @"section": @"FF",
                @"group": @"fps"
            }
        ];
    });
    return definitions;
}

NSDictionary *ExternalBuiltInPatchProject(NSDictionary *definition) {
    if (![definition isKindOfClass:NSDictionary.class]) return nil;

    NSString *resource = definition[@"resource"];
    NSDictionary *project = nil;
    if (resource.length) {
        NSData *data = BuiltInPatchResourceData(resource, definition[@"section"]);
        NSDictionary *decoded = data
            ? [ExternalPatchCore decodePackageData:data password:nil error:nil]
            : nil;
        project = decoded[@"project"];
    }

    if (!project) return nil;
    NSMutableDictionary *result = [project mutableCopy];
    result[@"id"] = definition[@"projectID"];
    result[@"name"] = definition[@"name"];
    result[@"updatedAt"] = [NSDate date];
    return result;
}