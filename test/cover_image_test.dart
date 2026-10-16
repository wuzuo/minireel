import 'package:flutter_test/flutter_test.dart';
import 'package:minireel/features/shared/widgets.dart';

void main() {
  group('HEIC cover rewrite', () {
    const signed =
        'https://p3-reading-sign.fqnovelpic.com/novel-pic/'
        '1120b94767374914e25a7b13de8c4e9d~tplv-81nmtwyey9-'
        'superreso-aifit:400:0.heic?lk3s=64477e16&x-expires=1&x-signature=abc';

    test('rewrites fqnovelpic HEIC to unsigned byteimg jpeg', () {
      expect(
        heicToByteimgJpeg(signed),
        'https://p3-novel.byteimg.com/novel-pic/'
        '1120b94767374914e25a7b13de8c4e9d~tplv-81nmtwyey9-'
        'superreso-aifit:400:0.jpeg',
      );
    });

    test('preserves the numeric host prefix', () {
      const other =
          'https://p9-reading-sign.fqnovelpic.com/novel-pic/abc.heic';
      expect(
        heicToByteimgJpeg(other),
        'https://p9-novel.byteimg.com/novel-pic/abc.jpeg',
      );
    });

    test('returns null for non-HEIC / non-fqnovelpic urls', () {
      expect(
        heicToByteimgJpeg(
          'https://p6-novel.byteimg.com/novel-pic/abc~tplv-x.image',
        ),
        isNull,
      );
      expect(
        heicToByteimgJpeg(
          'https://p3-reading-sign.fqnovelpic.com/novel-pic/abc.jpeg',
        ),
        isNull,
      );
      expect(heicToByteimgJpeg(''), isNull);
    });
  });
}
