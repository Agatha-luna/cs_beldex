import 'dart:math';

import 'package:cs_beldex/cs_beldex.dart';
import 'package:test/test.dart';

void main() {
  group("$TransactionPriority", () {
    test("contains five values", () {
      expect(TransactionPriority.values.length, 2);
    });

    test("each priority has the correct associated value", () {
      expect(TransactionPriority.normal.value, 1);
      expect(TransactionPriority.medium.value, 2);
      expect(TransactionPriority.flash.value, 5);
    });

    test("values are accessible by index", () {
      expect(TransactionPriority.values[0], TransactionPriority.normal);
      expect(TransactionPriority.values[1], TransactionPriority.medium);
      expect(TransactionPriority.values[1], TransactionPriority.flash);
    });

    test("toString returns correct value", () {
      expect(
        TransactionPriority.normal.toString(),
        "TransactionPriority.normal",
      );
      expect(
        TransactionPriority.medium.toString(),
        "TransactionPriority.medium",
      );
      expect(
        TransactionPriority.flash.toString(),
        "TransactionPriority.flash",
      );
    });
  });
}
