import XCTest
@testable import BrimScan

final class BTMParserTests: XCTestCase {
    func testParserExtractsRecords() {
        let dump = """
========================
 Records for UID -2 : FFFFEEEE-DDDD-CCCC-BBBB-AAAAFFFFFFFE
========================

 ServiceManagement migrated: true
 LaunchServices registered: false

 Items:

 #1:
                 UUID: C60CC267-53F9-447A-ABCB-37288CD56F64
                 Name: TestApp
       Developer Name: (null)
                 Type: app (0x2)
                Flags: [  ] (0)
          Disposition: [disabled, allowed, not notified] (0x2)
           Identifier: 2.com.google.Brim.TestApp
                  URL: /Users/501/Developer/brim/TestApp.app
           Generation: 0
    Bundle Identifier: com.google.Brim.TestApp
  Embedded Item Identifiers:
    #1: 16.com.google.Brim.daemon

 #2:
                 UUID: D76AFA0C-2F3E-4818-8187-126043A5FD57
                 Name: BrimHelper
       Developer Name: (null)
                 Type: daemon (0x10)
                Flags: [  ] (0)
          Disposition: [enabled, allowed, notified] (0xb)
                  URL: /Library/PrivilegedHelperTools/com.brim.helper
"""
        let parser = BTMParser()
        let records = parser.parse(dump: dump)
        
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].uuid, "C60CC267-53F9-447A-ABCB-37288CD56F64")
        XCTAssertEqual(records[0].name, "TestApp")
        XCTAssertEqual(records[0].developerName, "(null)")
        XCTAssertEqual(records[0].type, "app")
        XCTAssertEqual(records[0].disposition, "[disabled, allowed, not notified] (0x2)")
        XCTAssertEqual(records[0].identifier, "2.com.google.Brim.TestApp")
        XCTAssertEqual(records[0].url?.path, "/Users/501/Developer/brim/TestApp.app")
        XCTAssertEqual(records[0].bundleIdentifier, "com.google.Brim.TestApp")
        
        XCTAssertEqual(records[1].uuid, "D76AFA0C-2F3E-4818-8187-126043A5FD57")
        XCTAssertEqual(records[1].type, "daemon")
        XCTAssertEqual(records[1].url?.path, "/Library/PrivilegedHelperTools/com.brim.helper")
    }
}
