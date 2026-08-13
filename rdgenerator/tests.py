from io import BytesIO
import base64
import importlib.util
from pathlib import Path
import tempfile
from unittest.mock import Mock, patch

from django.core.cache import cache
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import RequestFactory, SimpleTestCase
from PIL import Image
from requests import RequestException

from .forms import GenerateForm, RUSTDESK_VERSION_CACHE_KEY, get_rustdesk_version_choices
from .views import _collect_extra_brands, _sanitize_brand_suffix, _sanitize_output_name


def load_apply_custom_server():
    script_path = Path(__file__).resolve().parents[1] / '.github' / 'scripts' / 'apply-custom-server.py'
    spec = importlib.util.spec_from_file_location('apply_custom_server', script_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.apply_custom_server


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


class CustomServerTests(SimpleTestCase):
    def test_custom_server_values_are_applied(self):
        apply_custom_server = load_apply_custom_server()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'libs' / 'hbb_common' / 'src' / 'config.rs'
            common = root / 'src' / 'common.rs'
            config.parent.mkdir(parents=True)
            common.parent.mkdir(parents=True)
            config.write_text(
                'rs-ny.rustdesk.com\nOeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=',
                encoding='utf-8',
            )
            common.write_text('https://admin.rustdesk.com', encoding='utf-8')

            apply_custom_server(root, 'host.example', 'custom-key', 'https://api.example')

            self.assertEqual(config.read_text(encoding='utf-8'), 'host.example\ncustom-key')
            self.assertEqual(common.read_text(encoding='utf-8'), 'https://api.example')


class WindowsArtifactNamingTests(SimpleTestCase):
    def test_all_windows_brands_use_underscore_before_direction(self):
        scripts = Path(__file__).resolve().parents[1] / '.github' / 'scripts'
        batch = (scripts / 'build-windows-brand-batch.ps1').read_text(encoding='utf-8')
        x64 = (scripts / 'build-windows-variants.ps1').read_text(encoding='utf-8')
        x86 = (scripts / 'build-windows-x86-variants.ps1').read_text(encoding='utf-8')

        self.assertIn("$env:RDGEN_DIRECTION_SEPARATOR = '_'", batch)
        self.assertIn("{ '_' } else { $env:RDGEN_DIRECTION_SEPARATOR }", x64)
        self.assertIn("{ '_' } else { $env:RDGEN_DIRECTION_SEPARATOR }", x86)


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
        self.assertEqual(len(choices), 11)
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
        self.assertContains(response, 'id="id_telegramNotifications"')
        self.assertFalse(response.context['form'].fields['telegramNotifications'].initial)
