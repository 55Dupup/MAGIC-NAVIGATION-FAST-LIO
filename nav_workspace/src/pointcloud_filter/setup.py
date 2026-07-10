from setuptools import setup

package_name = 'pointcloud_filter'

setup(
    name=package_name,
    version='1.0.0',
    packages=[package_name],
    package_dir={'': 'src'},
    data_files=[
        ('share/ament_index/resource_index/packages',
            ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='user',
    maintainer_email='user@example.com',
    description='Point cloud range filter node for LiDAR data',
    license='MIT',
    tests_require=['pytest'],
    entry_points={
        'console_scripts': [
            'range_filter = pointcloud_filter.range_filter:main',
        ],
    },
)
