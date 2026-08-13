from io import BytesIO
import base64
from unittest.mock import Mock, patch

from django.core.cache import cache
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import RequestFactory, SimpleTestCase
from PIL import Image
from requests import RequestException

from .forms import GenerateForm, RUSTDESK_VERSION_CACHE_KEY, get_rustdesk_version_choices
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


class RustDeskVersionChoiceTests(SimpleTestCase):
    def setUp(self):
        cache.delete(RUSTDESK_VERSION_CACHE_KEY)

    def tearDown(self):
        cache.delete(RUSTDESK_VERSION_CACHE_KEY)

    @patch('rdgenerator.forms.requests.get')
    def test_official_stable_releases_are_sorted_and_used_as_default(self, get):
        response = Mock()
        response.raise_for_status.return_value = None
        response.json.return_value = [
            {'tag_name': '1.5.0', 'draft': False, 'prerelease': False},
            {'tag_name': '1.6.0-beta.1', 'draft': False, 'prerelease': True},
            {'tag_name': 'nightly', 'draft': False, 'prerelease': True},
        ]
        get.return_value = response

        choices = get_rustdesk_version_choices()
        form = GenerateForm()

        self.assertEqual(choices[:2], [('master', 'nightly'), ('1.5.0', '1.5.0')])
        self.assertIn(('1.4.9', '1.4.9'), choices)
        self.assertEqual(form.fields['version'].initial, '1.5.0')

    @patch('rdgenerator.forms.requests.get', side_effect=RequestException('offline'))
    def test_unexpected_fetch_failure_keeps_generator_usable(self, _get):
        choices = get_rustdesk_version_choices()
        self.assertEqual(choices[0], ('master', 'nightly'))
        self.assertIn(('1.4.9', '1.4.9'), choices)


class GeneratorPageTests(SimpleTestCase):
    @patch(
        'rdgenerator.forms.get_rustdesk_version_choices',
        return_value=[('master', 'nightly'), ('1.4.9', '1.4.9')],
    )
    def test_generator_renders_multiplatform_controls(self, _choices):
        response = self.client.get('/generator')

        self.assertEqual(response.status_code, 200)
        self.assertContains(response, 'id="id_platform" multiple')
        self.assertContains(response, 'function getSelectedPlatforms()')
        self.assertContains(response, "requestData.delete('platform')")
