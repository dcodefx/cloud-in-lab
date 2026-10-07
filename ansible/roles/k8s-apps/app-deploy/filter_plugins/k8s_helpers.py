import re
import unicodedata


class FilterModule:
    def filters(self):
        return {
            'validate_hostname': self.validate_hostname,
            'to_kubernetes_name': self.to_kubernetes_name,
            'arch_image': self.arch_image,
        }

    @staticmethod
    def validate_hostname(value):
        if not isinstance(value, str):
            return False
        pattern = r'^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'
        return bool(re.match(pattern, value))

    @staticmethod
    def to_kubernetes_name(value):
        value = unicodedata.normalize('NFKD', str(value)).encode('ASCII', 'ignore').decode('ascii')
        value = re.sub(r'[^a-zA-Z0-9-]', '-', value.lower())
        value = re.sub(r'-+', '-', value).strip('-')
        if len(value) > 253:
            value = value[:253].rstrip('-')
        if not value:
            value = 'default'
        return value

    @staticmethod
    def arch_image(repo, tag=None, arch=None):
        if arch:
            tag = f'{tag}-{arch}' if tag else arch
        return f'{repo}:{tag}' if tag else repo
