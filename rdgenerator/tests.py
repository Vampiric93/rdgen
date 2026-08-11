from io import BytesIO
import base64

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import RequestFactory, SimpleTestCase
from PIL import Image

from .views import _collect_extra_brands, _sanitize_brand_suffix, _sanitize_output_name


def png_file(name, size=(64, 64)):
    output = BytesIO()
    Image.new('RGBA', size, (20, 80, 160, 255)).save(output, format='PNG')
    return SimpleUploadedFile(name, output.getvalue(), content_type='image/png')


def png_data_uri(size=(64, 64)):
    upload = png_file('saved.png', size)
    return 'data:image/png;base64,' + base64.b64encode(upload.read()).decode()


class BatchBrandingTests(SimpleTestCase):
    def setUp(self):
        self.factory = RequestFactory()

    def test_output_name_is_sanitized(self):
        self.assertEqual(_sanitize_output_name('Second Brand!'), 'Second_Brand_')
        self.assertEqual(_sanitize_brand_suffix(''), '')
        with self.assertRaises(ValueError):
            _sanitize_output_name('Клиент')

    def test_extra_brand_uses_given_suffix(self):
        request = self.factory.post('/generator', {
            'extra_brand_id': '7',
            'extra_suffix_7': 'secondbrand',
            'extra_iconfile_7': png_file('icon.png'),
            'extra_logofile_7': png_file('logo.png', (200, 60)),
        })
        brands = _collect_extra_brands(request)
        self.assertEqual(len(brands), 1)
        self.assertEqual(brands[0]['suffix'], 'secondbrand')

    def test_empty_suffix_uses_brand_number(self):
        request = self.factory.post('/generator', {
            'extra_brand_id': ['3', '8'],
            'extra_suffix_3': '',
            'extra_suffix_8': '',
            'extra_iconfile_3': png_file('one.png'),
            'extra_iconfile_8': png_file('two.png'),
        })
        brands = _collect_extra_brands(request)
        self.assertEqual([brand['suffix'] for brand in brands], ['2', '3'])

    def test_non_square_extra_icon_is_rejected(self):
        request = self.factory.post('/generator', {
            'extra_brand_id': '1',
            'extra_iconfile_1': png_file('wide.png', (100, 50)),
        })
        with self.assertRaisesRegex(ValueError, 'square'):
            _collect_extra_brands(request)

    def test_imported_base64_brand_assets_are_accepted(self):
        request = self.factory.post('/generator', {
            'extra_brand_id': '2',
            'extra_suffix_2': 'imported',
            'extra_iconbase64_2': png_data_uri(),
            'extra_logobase64_2': png_data_uri((200, 60)),
        })
        brands = _collect_extra_brands(request)
        self.assertTrue(brands[0]['iconfile'].startswith('data:image/png;base64,'))
        self.assertTrue(brands[0]['logofile'].startswith('data:image/png;base64,'))
