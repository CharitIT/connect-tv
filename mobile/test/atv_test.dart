import 'package:connect_tv/adb/adb_crypto.dart';
import 'package:connect_tv/atv/atv_cert.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('remote certificate carries the key and can be read back', () {
    final key = AdbKey.generate();
    final id = AtvIdentity.create(key);
    expect(id.certPem, startsWith('-----BEGIN CERTIFICATE-----'));
    expect(id.keyPem, startsWith('-----BEGIN RSA PRIVATE KEY-----'));

    final der = Uri.parse('data:;base64,${id.certPem.split('\n').where((l) => !l.startsWith('-----')).join()}')
        .data!
        .contentAsBytes();
    final pub = rsaPublicKeyOfCert(der);
    expect(pub.n, key.n);
    expect(pub.e, key.e);

    final again = AtvIdentity.deserialize(id.serialize());
    expect(again.certPem, id.certPem);
    expect(again.n, key.n);
  });

  test('unsignedBytes drops leading zeros', () {
    expect(unsignedBytes(BigInt.from(65537)), [1, 0, 1]);
    expect(unsignedBytes(BigInt.from(255)), [255]);
  });
}
