require 'dmtest/log'
require 'dmtest/process'
require 'dmtest/utils'
require 'dmtest/tags'
require 'dmtest/disk-units'
require 'dmtest/thinp-test'
require 'timeout'

#----------------------------------------------------------------

class NeedsCheckTests < ThinpTestCase
  include Tags
  include Utils
  include TinyVolumeManager
  include DiskUnits

  def setup
    super
    @low_water_mark = 0
    @data_block_size = 128
  end

  def pool_table(size)
    Table.new(ThinPoolTarget.new(size, @metadata_dev, @data_dev,
                                 @data_block_size, @low_water_mark))
  end

  #--------------------------------

  tag :thinp_target

  def test_commit_failure_sets_needs_check
    tvm = VM.new
    tvm.add_allocation_volume(@metadata_dev, 0, dev_size(@metadata_dev))
    tvm.add_volume(linear_vol('metadata', dev_size(@metadata_dev)))

    volume_size = gig(3)

    with_dev(tvm.table('metadata')) do |metadata|
      wipe_device(metadata, 8)

      table = Table.new(ThinPoolTarget.new(volume_size, metadata, @data_dev,
                                           @data_block_size, 0))

      with_dev(table) do |pool|
        with_new_thin(pool, volume_size, 0) do |thin|
          wipe_device(thin, 128)

          begin
            thin.pause do
              pool.pause do
                # Establish flakey metadata.  We need the superblock to
                # remain working.
                superblock_size = 8
                flakey_table = Table.new(LinearTarget.new(8, @metadata_dev, 0),
                                         FlakeyTarget.new(dev_size(@metadata_dev) - superblock_size,
                                                          @metadata_dev, 8, 0, 60))
                metadata.pause do
                  metadata.load(flakey_table)
                end
              end
            end

            wipe_device(thin, 256)
            assert(read_only_or_fail_mode?(pool))
          ensure
            # Put the metadata dev back
            metadata.pause do
              metadata.load(tvm.table('metadata'))
            end
          end
        end
      end

      # We can bring up the pool, but it will have immediately fallen
      # back to read_only mode.
      with_dev(table) do |pool|
        assert(read_only_mode?(pool))
      end

      # FIXME: use tools to clear needs_check mode
      ProcessControl.run("thin_check --clear-needs-check-flag #{metadata}")

      # Now we should be able to run in write mode
      with_dev(table) do |pool|
        assert(write_mode?(pool))
      end
    end
  end
end

#----------------------------------------------------------------
