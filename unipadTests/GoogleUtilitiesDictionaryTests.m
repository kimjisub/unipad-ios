#import <XCTest/XCTest.h>

// Resolve the class from the actual app image rather than linking a second test
// copy of GoogleUtilities. FirebaseManager disables server collection in XCTest.
@interface GoogleUtilitiesDictionaryTests : XCTestCase
@end

@implementation GoogleUtilitiesDictionaryTests

- (void)testLinkedDictionaryIgnoresNilKeysAndPreservesNormalOperations {
  Class dictionaryClass = NSClassFromString(@"GULMutableDictionary");
  XCTAssertNotNil(dictionaryClass, @"The app must link the upstream dictionary being checked");
  id dictionary = [[dictionaryClass alloc] init];
  [dictionary setObject:@"kept" forKey:@"existing"];

  // Intentionally violate the caller contract to cover malformed server input.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
  [dictionary setObject:@"ignored" forKey:nil];
  [dictionary setObject:@"ignored" forKeyedSubscript:nil];
#pragma clang diagnostic pop
  // Reads wait for preceding asynchronous writes; a guard inside the wrong
  // queue would already have terminated this isolated local-only test process.
  XCTAssertEqual([dictionary count], 1u);
  XCTAssertEqualObjects([dictionary objectForKey:@"existing"], @"kept");
  [dictionary removeAllObjects];
  [dictionary setObject:@"one" forKey:@"normal"];
  XCTAssertEqualObjects([dictionary objectForKey:@"normal"], @"one");
  [dictionary setObject:@"two" forKeyedSubscript:@"normal"];
  XCTAssertEqualObjects([dictionary objectForKeyedSubscript:@"normal"], @"two");
  [dictionary removeObjectForKey:@"normal"];
  XCTAssertNil([dictionary objectForKey:@"normal"]);
  XCTAssertEqual([dictionary count], 0u);
  [dictionary setObject:@"valid" forKey:@""];
  XCTAssertEqualObjects([dictionary objectForKey:@""], @"valid");
  [dictionary removeAllObjects];
  XCTAssertEqual([dictionary count], 0u);
}

@end
