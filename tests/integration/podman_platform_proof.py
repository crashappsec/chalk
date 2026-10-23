def proves_arm_emulation(builder_status, builder_os, builder_architecture,
                         builder_remote, arm_status, arm_machine):
    return (
        builder_status == 0 and
        builder_os == 'linux' and
        builder_architecture == 'amd64' and
        builder_remote is False and
        arm_status == 0 and
        arm_machine == 'aarch64'
    )
