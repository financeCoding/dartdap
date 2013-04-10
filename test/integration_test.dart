

import 'package:unittest/unittest.dart';
import 'package:dartdap/ldap_client.dart';


import 'dart:math';
import 'dart:isolate';
import 'dart:async';


main() {
  LDAPConnection ldap;
  var ldapConfig = new LDAPConfiguration("test/ldap.yaml");

  initLogging();

  group('LDAP Integration ', () {
    // create a connection. Return a future that completes when
    // the connection is available and bound
    setUp( () {
      return ldapConfig.getConnection()
          .then( (LDAPConnection l) => ldap =l );
    });

    tearDown( () {
      // nothing to do. We keep the connection open
    });

    test('Search Test', () {
     var attrs = ["dn", "cn", "objectClass"];

     ldap.onError = expectAsync1((e) => expect(false, 'Should not be reached'), count: 0);

     var filter = Filter.substring("cn=A*");
     var sb = ldap.search("dc=example,dc=com", filter, attrs);

     sb.listen( (SearchEntry entry) {
       print("Found ${entry}");
     } );

     var notFilter = Filter.not(filter);

     sb = ldap.search("dc=example,dc=com", notFilter, attrs);
     /*-------------------
     sb.then( expectAsync1( (SearchResult r) {
       print("Not Search Completed r = ${r}");
     }, count: 1));

  */
    //c.close();

   });


   test('add/modify/delete request', () {
      var dn = "uid=mmouse,ou=People,dc=example,dc=com";

      // clean up first from any failed test
      ldap.delete(dn).then( (result) {
        print("delete result= $result");
      }).catchError( (e) {
        print("delete result ${e.error.resultCode}");
      });

      var attrs = { "cn" : "Mickey Mouse", "uid": "mmouse", "sn":"Mouse",
                    "objectClass":["inetorgperson"]};

      // add mickey to directory
      ldap.add(dn, attrs).then( expectAsync1((r) {
        expect( r.resultCode, equals(0));
        // modify mickey's sn
        var m = new Modification.replace("sn", ["Sir Mickey"]);
        ldap.modify(dn, [m]).then( expectAsync1((result) {
          expect(result.resultCode,equals(0));
          // finally delete mickey
          ldap.delete(dn).then( expectAsync1((result) {
            expect(result.resultCode,equals(0));
          }));
        }));
      }));


   }); // end test

   test('test error handling', () {

     // dn we know will fail to delete as it does not exist
     var dn = "uid=FooDoesNotExist,ou=People,dc=example,dc=com";

     ldap.delete(dn)
      .then( expectAsync1( (r) {
          //print("Result = ${r}");
          expect(false,'Future catchError should have been called');
          }, count:0))
      .catchError( expectAsync1( (e) {
        expect( e.error.resultCode, equals(ResultCode.NO_SUCH_OBJECT));
      }));

   }); // end test

  }); // end grou
}