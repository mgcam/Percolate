#--
#
# Copyright (C) 2010 Genome Research Ltd. All rights reserved.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

require 'fileutils'
require 'tmpdir'
require 'yaml'
require 'test/unit'

libpath = File.expand_path('../lib')
$:.unshift(libpath) unless $:.include?(libpath)

require 'percolate'

module TestPercolate
  class TestPercolator < Test::Unit::TestCase
    include Percolate

    def setup
      super
    end

    def teardown
      super
    end

    def data_path
      File.expand_path File.join File.dirname(__FILE__), '..', 'data'
    end

    def test_path
      File.expand_path File.join File.dirname(__FILE__), '..', 'test'
    end

    def test_read_config
      open(File.join data_path, 'percolate_config.yml') do |file|
        config = YAML.load(file)

        assert_equal('test', config['root_dir'])
      end
    end

    def test_new_percolator
      percolator = Percolator.new({'root_dir' => data_path})
      assert_equal(data_path, percolator.root_dir)
    end

    def test_find_definitions
      percolator = Percolator.new({'root_dir' => data_path})
      assert_equal(['test_def1.yml', 'test_def2.yml'],
                   percolator.find_definitions.sort.map { |file| File.basename file } )
    end

    def test_find_run_files
      percolator = Percolator.new({'root_dir' => data_path})
      assert_equal(['test_def1.run'],
                   percolator.find_run_files.map { |file| File.basename file } )
    end

    def test_find_new_definitions
      percolator = Percolator.new({'root_dir' => data_path})
      assert_equal(['test_def2.yml'],
                   percolator.find_new_definitions.map { |file| File.basename file } )
    end

    def test_read_definition
      percolator = Percolator.new({'root_dir' => data_path})
      defn1 = percolator.read_definition File.join percolator.run_dir, 'test_def1.yml'
      defn2 = percolator.read_definition File.join percolator.run_dir, 'test_def2.yml'

      assert defn1.is_a? Array
      assert_equal(Percolate::EmptyWorkflow, defn1[0])
      assert_equal(['/tmp'], defn1[1])

      assert defn2.is_a? Array
      assert_equal(Percolate::FailingWorkflow, defn2[0])
      assert_equal(['/tmp'], defn2[1])
    end

    def test_percolate_tasks_pass
      begin
        percolator = Percolator.new({'root_dir' => data_path})
        defn_file = File.join percolator.run_dir, 'test_def1_tmp.yml'
        run_file = File.join percolator.run_dir, 'test_def1_tmp.run'

        FileUtils.cp File.join(percolator.run_dir, 'test_def1.yml'), defn_file
        assert(percolator.percolate_tasks(defn_file).passed?)

        [defn_file, run_file].each do |file|
          assert(File.exists? File.join percolator.pass_dir, File.basename(file))
        end
      ensure
        [defn_file, run_file].each do |file|
          File.delete File.join(percolator.pass_dir, File.basename(file))
        end
      end
    end

    def test_percolate_tasks_fail
      begin
        percolator = Percolator.new({'root_dir' => data_path})
        defn_file = File.join percolator.run_dir, 'test_def2_tmp.yml'
        run_file = File.join percolator.run_dir, 'test_def2_tmp.run'

        FileUtils.cp File.join(percolator.run_dir, 'test_def2.yml'), defn_file
        assert(percolator.percolate_tasks(defn_file).failed?)

        [defn_file, run_file].each do |file|
          assert(File.exists? File.join(percolator.fail_dir, File.basename(file)))
        end
      ensure
        [defn_file, run_file].each do |file|
          File.delete File.join(percolator.fail_dir, File.basename(file))
        end
      end
    end
  end
end